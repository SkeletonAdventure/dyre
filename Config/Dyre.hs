{- |
Dyre is a library for configuring your Haskell programs. Like Xmonad,
programs configured with Dyre will look for a configuration file written
in Haskell, which essentially defines a custom program configured exactly
as the user wishes it to be. And since the configuration is written in
Haskell, the user is free to do anything they might wish in the context
of configuring the program.

Dyre places emphasis on elegance of operation and ease of integration
with existing applications. The 'wrapMain' function is the sole entry
point for Dyre. When partially applied with a parameter structure, it
wraps around the 'realMain' value from that structure, yielding an almost
identical function which has been augmented with dynamic recompilation
functionality.

The "Config.Dyre.Relaunch" module provides the ability to restart the
program (recompiling if applicable), and persist state across restarts,
but it has no impact whatsoever on the rest of the library whether it
is used or not.

= Writing a program that uses Dyre

The following example program uses most of Dyre's major features:

@
-- DyreExample.hs --
module DyreExample
  ( Config(..)
  , defaultConfig
  , dyreExample
  )
where

import qualified "Config.Dyre" as Dyre
import "Config.Dyre.Relaunch"

import System.IO

data Config = Config { message :: String, errorMsg :: Maybe String }
data State  = State { bufferLines :: [String] } deriving (Read, Show)

defaultConfig :: Config
defaultConfig = Config "Dyre Example v0.1" Nothing

showError :: Config -> String -> Config
showError cfg msg = cfg { errorMsg = Just msg }

realMain Config{message = message, errorMsg = errorMsg } = do
    (State buffer) <- 'Config.Dyre.Relaunch.restoreTextState' $ State []
    case errorMsg of
         Nothing -> return ()
         Just em -> putStrLn $ "Error: " ++ em
    putStrLn message
    traverse putStrLn . reverse $ buffer
    putStr "> " *> hFlush stdout
    input <- getLine
    case input of
         "exit" -> return ()
         "quit" -> return ()
         other  -> 'Config.Dyre.Relaunch.relaunchWithTextState' (State $ other:buffer) Nothing

dyreExample = Dyre.'Config.Dyre.wrapMain' $ Dyre.'Config.Dyre.newParams' "dyreExample" realMain showError
@

All of the program logic is contained in the @DyreExample@ module.
The module exports the 'Config' data type, a @defaultConfig@, and
the @dyreExample@ function which, when applied to a 'Config',
returns an @(IO a)@ value to be used as @main@.

The @Main@ module of the program is trivial.  All that is required
is to apply @dyreExample@ to the default configuration:

@
-- Main.hs --
import DyreExample
main = dyreExample defaultConfig
@

= Custom program configuration

Users can create a custom configuration file that overrides some or
all of the default configuration:

@
-- ~\/.config\/dyreExample\/dyreExample.hs --
import DyreExample
main = dyreExample $ defaultConfig { message = "Dyre Example v0.1 (Modified)" }
@

When a program that uses Dyre starts, Dyre checks to see if a custom
configuration exists.  If so, it runs a custom executable.  Dyre
(re)compiles and caches the custom executable the first time it sees
the custom config or whenever the custom config has changed.

If a custom configuration grows large, you can extract parts of it
into one or more files under @lib/@.  For example:

@
-- ~\/.config\/dyreExample\/dyreExample.hs --
import DyreExample
import Message
main = dyreExample $ defaultConfig { message = Message.msg }
@

@
-- ~\/.config\/dyreExample\/lib/Message.hs --
module Message where
msg = "Dyre Example v0.1 (Modified)"
@

== Working with the Cabal store

For a Dyre-enabled program to work when installed via @cabal
install@, it needs to add its library directory as an extra include
directory for compilation.  The library /package name/ __must__
match the Dyre 'projectName' for this to work.  For example:

@
import Paths_dyreExample (getLibDir)

dyreExample cfg = do
  libdir <- getLibDir
  let params = (Dyre.'Config.Dyre.newParams' "dyreExample" realMain showError)
        { Dyre.'Config.Dyre.includeDirs' = [libdir] }
  Dyre.'Config.Dyre.wrapMain' params cfg
@

See also the Cabal
<https://cabal.readthedocs.io/en/3.2/developing-packages.html#accessing-data-files-from-package-code Paths_pkgname feature documentation>.

== Specifying the compiler

If the compiler that Dyre should use is not available as @ghc@, set
the @HC@ environment variable when running the main program:

@
export HC=\/opt\/ghc\/$GHC_VERSION\/bin\/ghc
dyreExample  # Dyre will use $HC for recompilation
@


= Configuring Dyre

Program authors configure Dyre using the 'Params' type.  This type
controls Dyre's behaviour, not the main program logic (the example
uses the @Config@ type for that).

Use 'newParams' to construct a 'Params' value.  The three arguments are:

- /Application name/ (a @String@).  This affects the names of files and directories
  that Dyre uses for config, cache and logging.

- The /real main/ function of the program, which has type
  @(cfgType -> IO a)@.  @cfgType@ is the main program config type,
  and @a@ is usually @()@.

- The /show error/ function, which has type @(cfgType -> String ->
  cfgType)@.  If compiling the custom program fails, Dyre uses this
  function to set the compiler output in the main program's
  configuration.  The main program can then display the error string
  to the user, or handle it however the author sees fit.

The 'Params' type has several other fields for modifying Dyre's
behaviour.  'newParams' uses reasonable defaults, but behaviours you
can change include:

- Where to look for custom configuration ('configDir').  By default
  Dyre will look for @$XDG_CONFIG_HOME\/\<appName\>\/\<appName\>.hs@,

- Where to cache the custom executable and other files ('cacheDir').
  By default Dyre will use @$XDG_CACHE_HOME\/\<appName\>\/@.

- Extra options to pass to GHC when compiling the custom executable
  ('ghcOpts').  Default: none.

See 'Params' for descriptions of all the fields.

-}
module Config.Dyre
  (
    wrapMain
    , Params(..)
    , newParams
    , defaultParams
  ) where

import System.IO           ( hPutStrLn, stderr )
import System.Directory    ( doesFileExist, canonicalizePath )
import System.Environment  (getArgs)
import GHC.Environment     (getFullArgs)
import Control.Exception   (assert)

import Control.Monad       ( when )

import Config.Dyre.Params  ( Params(..), RTSOptionHandling(..) )
import Config.Dyre.Compile ( customCompile, getErrorString )
import Config.Dyre.Compat  ( customExec )
import Config.Dyre.Options ( getForceReconf, getDenyReconf
                           , withDyreOptions )
import Config.Dyre.Paths
  ( getPathsConfig, customExecutable, runningExecutable, configFile
  , checkFilesModified, PathsConfig (configMethod)
  )

-- | A set of reasonable defaults for configuring Dyre. The fields that
--   have to be filled are 'projectName', 'realMain', and 'showError'
--   (because their initial value is @undefined@).
--
-- Deprecated in favour of 'newParams' which takes the required
-- fields as arguments.
--
defaultParams :: Params cfgType a
defaultParams = Params
    { projectName  = undefined
    , configCheck  = True
    , configDir    = Nothing
    , buildScriptName = Just "build"
    , cacheDir     = Nothing
    , realMain     = undefined
    , showError    = undefined
    , includeDirs  = []
    , hidePackages = []
    , ghcOpts      = []
    , forceRecomp  = True
    , statusOut    = hPutStrLn stderr
    , rtsOptsHandling = RTSAppend []
    , includeCurrentDirectory = True
    }
{-# DEPRECATED defaultParams "Use 'newParams' instead" #-}

-- | Construct a 'Params' with the required values as given, and
-- reasonable defaults for everything else.
--
newParams
  :: String                  -- ^ 'projectName'
  -> (cfg -> IO a)          -- ^ 'realMain' function
  -> (cfg -> String -> cfg)  -- ^ 'showError' function
  -> Params cfg a
newParams name main err =
  defaultParams { projectName = name, realMain = main, showError = err }

-- | @wrapMain@ is how Dyre receives control of the program. It is expected
--   that it will be partially applied with its parameters to yield a @main@
--   entry point, which will then be called by the @main@ function, as well
--   as by any custom configurations.
--
-- @wrapMain@ returns whatever value is returned by the @realMain@ function
-- in the @params@ (if it returns at all).  In the common case this is @()@
-- but you can use Dyre with any @IO@ action.
--
wrapMain :: Params cfgType a -> cfgType -> IO a
wrapMain params cfg = withDyreOptions params $
    -- Allow the 'configCheck' parameter to disable all of Dyre's recompilation
    -- checks, in favor of simply proceeding ahead to the 'realMain' function.
    if not $ configCheck params
       then realMain params cfg
       else do
        -- Get the important paths
        paths <- getPathsConfig params
        let tempBinary = customExecutable paths
            thisBinary = runningExecutable paths

        confExists <- doesFileExist (configFile $ configMethod paths)

        denyReconf  <- getDenyReconf
        forceReconf <- getForceReconf

        doReconf <- case (confExists, denyReconf, forceReconf) of
          (False, _, _) -> pure False  -- no config file
          (_, True, _)  -> pure False  -- deny overrules force
          (_, _, True)  -> pure True   -- avoid timestamp/hash checks
          (_, _, False) -> checkFilesModified paths

        when doReconf (customCompile params)

        -- If there's a custom binary and we're not it, run it. Otherwise
        -- just launch the main function, reporting errors if appropriate.
        -- Also we don't want to use a custom binary if the conf file is
        -- gone.
        errorData    <- getErrorString params
        customExists <- doesFileExist tempBinary

        case (confExists, customExists) of
          (False, _) ->
            -- There is no custom config.  Ignore custom binary if present.
            -- Run main binary and ignore errors file.
            enterMain Nothing
          (True, True) -> do
               -- Canonicalize the paths for comparison to avoid symlinks
               -- throwing us off. We do it here instead of earlier because
               -- canonicalizePath throws an exception when the file is
               -- nonexistent.
               thisBinary' <- canonicalizePath thisBinary
               tempBinary' <- canonicalizePath tempBinary
               if thisBinary' /= tempBinary'
                  then launchSub errorData tempBinary
                  else enterMain errorData
          (True, False) ->
            -- Config exists, but no custom binary.
            -- Looks like compile failed; run main binary with error data.
           enterMain errorData
  where launchSub errorData tempBinary = do
            statusOut params $ "Launching custom binary " ++ tempBinary ++ "\n"
            givenArgs <- handleRTSOptions $ rtsOptsHandling params
            -- Deny reconfiguration if a compile already failed.
            let arguments = case errorData of
                              Nothing -> givenArgs
                              Just _  -> "--deny-reconf":givenArgs
            -- Execute
            customExec tempBinary $ Just arguments
        enterMain errorData = do
            -- Show the error data if necessary
            let mainConfig = case errorData of
                                  Nothing -> cfg
                                  Just ed -> showError params cfg ed
            -- Enter the main program
            realMain params mainConfig

assertM :: Applicative f => Bool -> f ()
assertM b = assert b (pure ())

-- | Extract GHC runtime system arguments
filterRTSArgs :: [String] -> [String]
filterRTSArgs = filt False
  where
    filt _     []             = []
    filt _     ("--RTS":_)    = []
    filt False ("+RTS" :rest) = filt True  rest
    filt True  ("-RTS" :rest) = filt False rest
    filt False (_      :rest) = filt False rest
    filt True  (arg    :rest) = arg:filt True rest
    --filt state args           = error $ "Error filtering RTS arguments in state " ++ show state ++ " remaining arguments: " ++ show args

editRTSOptions :: [String] -> RTSOptionHandling -> [String]
editRTSOptions _ (RTSReplace ls) = ls
editRTSOptions opts (RTSAppend ls)  = opts ++ ls

handleRTSOptions :: RTSOptionHandling -> IO [String]
handleRTSOptions h = do fargs <- getFullArgs
                        args  <- getArgs
                        let rtsArgs = editRTSOptions (filterRTSArgs fargs) h
                        assertM $ "--RTS" `notElem` rtsArgs
                        pure $ case rtsArgs of
                          [] | "+RTS" `elem` args -> "--RTS":args
                             | otherwise          -> args  -- cleaner output
                          _                       -> "+RTS" : rtsArgs ++ "--RTS" : args

