{- |

File paths of interest to Dyre, and related values.

-}
module Config.Dyre.Paths where

import Control.Monad ( filterM )
import Data.List ( isSuffixOf )
import System.Info                    (os, arch)
import System.FilePath
  ( (</>), (<.>), takeExtension, splitExtension, takeDirectory )
import System.Directory
  ( doesDirectoryExist
  , doesFileExist
  , getCurrentDirectory
  , getDirectoryContents
  , getModificationTime
  )
import System.Environment.XDG.BaseDir (getUserCacheDir, getUserConfigDir)
import System.Environment.Executable  (getExecutablePath)
import Data.Time

import Config.Dyre.Params
import Config.Dyre.Options
import Data.Maybe (fromJust)

data ConfigMethod =
  HaskellFile { configFile :: FilePath }
  | BuildScript { configFile :: FilePath }  

-- | Data type to make it harder to confuse which path is which.
data PathsConfig = PathsConfig
  { runningExecutable :: FilePath
  , customExecutable :: FilePath
  , configMethod :: ConfigMethod
  -- ^ Where Dyre looks for the custom configuration file, and how
  -- it uses it.
  , libsDirectory :: FilePath
  -- ^ @<configDir>/libs@.  This directory gets added to the GHC
  -- include path during compilation, so use configurations can be
  -- split up into modules.  Changes to files under this directory
  -- trigger recompilation.
  , cacheDirectory :: FilePath
  -- ^ Where the custom executable, object and interface files, errors
  -- file and other metadata get stored.
  }

-- | Determine a file name for the compiler to write to, based on
-- the 'customExecutable' path.
--
outputExecutable :: FilePath -> FilePath
outputExecutable path =
  let (base, ext) = splitExtension path
  in base <.> "tmp" <.> ext

-- | Return a 'PathsConfig', which records the current binary, the custom
--   binary, the config file, and the cache directory.
getPaths :: Params c r -> IO (FilePath, FilePath, ConfigMethod, FilePath, FilePath)
getPaths params@Params{projectName = pName, buildScriptName = bName} = do
    thisBinary <- getExecutablePath
    debugMode  <- getDebug
    cwd <- getCurrentDirectory
    cacheDir' <- case (debugMode, cacheDir params) of
                      (True,  _      ) -> return $ cwd </> "cache"
                      (False, Nothing) -> getUserCacheDir pName
                      (False, Just cd) -> cd
    confDir   <- case (debugMode, configDir params) of
                      (True,  _      ) -> return cwd
                      (False, Nothing) -> getUserConfigDir pName
                      (False, Just cd) -> cd
    buildScirptExists <- case bName of
      Just b -> doesFileExist (confDir </> b)
      Nothing -> pure False
    let
      tempBinary =
        cacheDir' </> pName ++ "-" ++ os ++ "-" ++ arch <.> takeExtension thisBinary
      configMethod' = if buildScirptExists
        then BuildScript $ confDir </> fromJust bName
        else HaskellFile $ confDir </> pName ++ ".hs"
      libsDir = confDir </> "lib"
    pure (thisBinary, tempBinary, configMethod', cacheDir', libsDir)

getPathsConfig :: Params cfg a -> IO PathsConfig
getPathsConfig params = do
  (cur, custom, conf, cache, libs) <- getPaths params
  pure $ PathsConfig cur custom conf libs cache

-- | Check if a file exists. If it exists, return Just the modification
--   time. If it doesn't exist, return Nothing.
maybeModTime :: FilePath -> IO (Maybe UTCTime)
maybeModTime path = do
    fileExists <- doesFileExist path
    if fileExists
       then Just <$> getModificationTime path
       else return Nothing

checkFilesModified :: PathsConfig -> IO Bool
checkFilesModified paths = do
  confTime <- maybeModTime (configFile $ configMethod paths)
  libFiles <- findHaskellFiles (libsDirectory paths)
  srcFiles <- case configMethod paths of
    HaskellFile _ -> pure []
    BuildScript _ -> findHaskellFiles $ takeDirectory (libsDirectory paths)
  libTimes <- traverse maybeModTime (libFiles ++ srcFiles)
  thisTime <- maybeModTime (runningExecutable paths)
  tempTime <- maybeModTime (customExecutable paths)
  pure $
    tempTime < confTime     -- config newer than custom bin
    || tempTime < thisTime  -- main bin newer than custom bin
    || any (tempTime <) libTimes

-- | Recursively find Haskell files (@.hs@, @.lhs@) at the given
-- location.
findHaskellFiles :: FilePath -> IO [FilePath]
findHaskellFiles d = do
  exists <- doesDirectoryExist d
  if exists
    then do
      nodes <- getDirectoryContents d
      let nodes' = map (d </>) . filter (`notElem` [".", ".."]) $ nodes
      files <- filterM isHaskellFile nodes'
      dirs  <- filterM doesDirectoryExist nodes'
      subfiles <- concat <$> traverse findHaskellFiles dirs
      pure $ files ++ subfiles
    else pure []
  where
    isHaskellFile f
      | any (`isSuffixOf` f) [".hs", ".lhs"] = doesFileExist f
      | otherwise = pure False
