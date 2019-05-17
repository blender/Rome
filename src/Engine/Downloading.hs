{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Engine.Downloading where

import           Caches.Common
import           Configuration                (carthageArtifactsBuildDirectoryForPlatform)
import           Control.Exception            (try)
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Reader         (ReaderT, ask, runReaderT,
                                               withReaderT)
import qualified Data.ByteString.Lazy         as LBS
import           Data.Carthage.TargetPlatform
import           Data.Either                  (lefts)
import           Data.Monoid                  ((<>))
import           Data.Romefile                (Framework (..))
import           System.Directory
import           System.FilePath              ((</>))
import           Types                        hiding (version)
import           Utils
import           Xcode.DWARF
import qualified Turtle

-- | Retrieves a Framework using the engine and unzip the contents
getFrameworkFromEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the Framework in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> ExceptT String (ReaderT (CachePrefix, Bool) IO) LBS.ByteString
getFrameworkFromEngine enginePath reverseRomeMap (FrameworkVersion f@(Framework fwn _ _) version) platform
  = do
    (CachePrefix cachePrefix, verbose) <- ask
    let frameworkLocalPath = cachePrefix </> remoteFrameworkUploadPath
    mapExceptT
      (withReaderT (const verbose))
      (getArtifactFromEngine enginePath frameworkLocalPath fwn
      )
 where
  remoteFrameworkUploadPath = remoteFrameworkPath platform reverseRomeMap f version


-- | Retrieves a .version file using the engine
getVersionFileFromEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> ProjectNameAndVersion
  -> ExceptT
       String
       (ReaderT (CachePrefix, Bool) IO)
       LBS.ByteString
getVersionFileFromEngine enginePath projectNameAndVersion = do
  (CachePrefix prefix, verbose) <- ask
  let finalVersionFileRemotePath = prefix </> versionFileRemotePath
  mapExceptT (withReaderT (const verbose)) $ getArtifactFromEngine
    enginePath
    finalVersionFileRemotePath
    versionFileName
 where
  versionFileName = versionFileNameForProjectName $ fst projectNameAndVersion
  versionFileRemotePath = remoteVersionFilePath projectNameAndVersion


-- | Retrieves a bcsymbolmap using the engine
getBcsymbolmapWithEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the dSYM
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> DwarfUUID -- ^ The UUID of the bcsymbolmap
  -> ExceptT
       String
       (ReaderT (CachePrefix, Bool) IO)
       LBS.ByteString
getBcsymbolmapWithEngine enginePath reverseRomeMap (FrameworkVersion f@(Framework fwn _ _) version) platform dwarfUUID
  = do
    (CachePrefix prefix, verbose) <- ask
    let finalRemoteBcsymbolmaploadPath = prefix </> remoteBcSymbolmapUploadPath
    mapExceptT (withReaderT (const verbose)) $ getArtifactFromEngine
      enginePath
      finalRemoteBcsymbolmaploadPath
      symbolmapName
 where
  remoteBcSymbolmapUploadPath =
    remoteBcsymbolmapPath dwarfUUID platform reverseRomeMap f version
  symbolmapName = fwn <> "." <> bcsymbolmapNameFrom dwarfUUID


-- | Retrieves a dSYM using the engine
getDSYMFromEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the dSYM
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> ExceptT
       String
       (ReaderT (CachePrefix, Bool) IO)
       LBS.ByteString
getDSYMFromEngine enginePath reverseRomeMap (FrameworkVersion f@(Framework fwn _ _) version) platform
  = do
    (CachePrefix prefix, verbose) <- ask
    let finalRemoteDSYMUploadPath = prefix </> remoteDSYMUploadPath
    mapExceptT (withReaderT (const verbose))
      $ getArtifactFromEngine enginePath finalRemoteDSYMUploadPath dSYMName
 where
  remoteDSYMUploadPath = remoteDsymPath platform reverseRomeMap f version
  dSYMName             = fwn <> ".dSYM"


-- | Retrieves a bcsymbolmap using the engine and unzip the contents
getAndUnzipBcsymbolmapWithEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the dSYM
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> DwarfUUID -- ^ The UUID of the bcsymbolmap
  -> ExceptT String (ReaderT (CachePrefix, Bool) IO) ()
getAndUnzipBcsymbolmapWithEngine enginePath reverseRomeMap fVersion@(FrameworkVersion f@(Framework fwn _ fwps) version) platform dwarfUUID
  = when (platform `elem` fwps) $ do
    (_, verbose) <- ask
    let symbolmapName = fwn <> "." <> bcsymbolmapNameFrom dwarfUUID
    binary <- getBcsymbolmapWithEngine enginePath
                                       reverseRomeMap
                                       fVersion
                                       platform
                                       dwarfUUID
    deleteFile (bcsymbolmapPath dwarfUUID) verbose
    unzipBinary binary symbolmapName (bcsymbolmapZipName dwarfUUID) verbose
 where
  platformBuildDirectory =
    carthageArtifactsBuildDirectoryForPlatform platform f
  bcsymbolmapZipName d = bcsymbolmapArchiveName d version
  bcsymbolmapPath d = platformBuildDirectory </> bcsymbolmapNameFrom d


-- | Retrieves all the bcsymbolmap files using the engine and unzip the contents
getAndUnzipBcsymbolmapsWithEngine'
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> ExceptT
       DWARFOperationError
       (ReaderT (CachePrefix, Bool) IO)
       ()
getAndUnzipBcsymbolmapsWithEngine' enginePath reverseRomeMap fVersion@(FrameworkVersion f@(Framework fwn _ fwps) _) platform
  = when (platform `elem` fwps) $ do

    dwarfUUIDs <- withExceptT (const ErrorGettingDwarfUUIDs)
      $ dwarfUUIDsFrom (frameworkDirectory </> fwn)
    eitherDwarfUUIDsOrSucces <- forM
      dwarfUUIDs
      (\dwarfUUID -> lift $ runExceptT
        (withExceptT (\e -> (dwarfUUID, e)) $ getAndUnzipBcsymbolmapWithEngine
          enginePath
          reverseRomeMap
          fVersion
          platform
          dwarfUUID
        )
      )

    let failedUUIDsAndErrors = lefts eitherDwarfUUIDsOrSucces
    unless (null failedUUIDsAndErrors) $ throwError $ FailedDwarfUUIDs
      failedUUIDsAndErrors
 where
  frameworkNameWithFrameworkExtension = appendFrameworkExtensionTo f
  platformBuildDirectory =
    carthageArtifactsBuildDirectoryForPlatform platform f
  frameworkDirectory =
    platformBuildDirectory </> frameworkNameWithFrameworkExtension


-- | Retrieves a Framework using the engine and unzip the contents
getAndUnzipFrameworkWithEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the Framework in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the Framework
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> ExceptT String (ReaderT (CachePrefix, Bool) IO) ()
getAndUnzipFrameworkWithEngine enginePath reverseRomeMap fVersion@(FrameworkVersion f@(Framework fwn _ fwps) version) platform
  = when (platform `elem` fwps) $ do
    (_, verbose) <- ask
    frameworkBinary <- getFrameworkFromEngine enginePath
                                          reverseRomeMap
                                          fVersion
                                          platform
    deleteFrameworkDirectory fVersion platform verbose
    unzipBinary frameworkBinary fwn frameworkZipName verbose
      <* ifExists
           frameworkExecutablePath
           (makeExecutable frameworkExecutablePath)
 where
  frameworkZipName        = frameworkArchiveName f version
  frameworkExecutablePath = frameworkBuildBundleForPlatform platform f </> fwn


-- | Retrieves a dSYM using the engine and unzip the contents
getAndUnzipDSYMWithEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> InvertedRepositoryMap -- ^ The map used to resolve from a `FrameworkVersion` to the path of the dSYM in the cache
  -> FrameworkVersion -- ^ The `FrameworkVersion` identifying the dSYM
  -> TargetPlatform -- ^ The `TargetPlatform` to limit the operation to
  -> ExceptT String (ReaderT (CachePrefix, Bool) IO) ()
getAndUnzipDSYMWithEngine enginePath reverseRomeMap fVersion@(FrameworkVersion f@(Framework fwn _ fwps) version) platform
  = when (platform `elem` fwps) $ do
    (_, verbose) <- ask
    dSYMBinary <- getDSYMFromEngine enginePath reverseRomeMap fVersion platform
    deleteDSYMDirectory fVersion platform verbose
    unzipBinary dSYMBinary fwn dSYMZipName verbose
  where dSYMZipName = dSYMArchiveName f version

-- | Retrieves an artifact using the engine
getArtifactFromEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> FilePath -- ^ The remote path 
  -> String -- ^ A colloquial name for the artifact
  -> ExceptT String (ReaderT Bool IO) LBS.ByteString
getArtifactFromEngine enginePath remotePath artifactName = do
  readerEnv@(verbose)            <- ask
  eitherArtifact :: Either IOError LBS.ByteString <- liftIO $ try $ runReaderT
    (downloadBinaryWithEngine enginePath remotePath artifactName)
    readerEnv
  case eitherArtifact of
    Left e ->
      throwError
        $  "Error: could not download "
        <> artifactName
        <> " : "
        <> show e
    Right artifactBinary -> return artifactBinary

-- | Downloads an artifact stored at a given path using the engine
downloadBinaryWithEngine
  :: FilePath -- ^ The `FilePath` to the engine
  -> FilePath
  -> FilePath
  -> (ReaderT Bool IO) LBS.ByteString
downloadBinaryWithEngine enginePath objectRemotePath objectName = do
    verbose <- ask
    let cmd = Turtle.fromString enginePath
    let sayFunc = if verbose then sayLnWithTime else sayLn
    when verbose
      $  sayLnWithTime
      $  "Invoking engine "
      <> show enginePath
      <> " to download "
      <> objectName
      <> " from: "
      <> objectRemotePath
    exitCode <- Turtle.proc
        cmd
        ["download", Turtle.fromString objectRemotePath, Turtle.fromString objectRemotePath]
        (return $ Turtle.unsafeTextToLine "")
    case exitCode of
        Turtle.ExitSuccess   -> return ()
        Turtle.ExitFailure n -> sayFunc 
          $  "Error: could not download "
          <> objectRemotePath
    binaryExists <- liftIO . doesFileExist $ objectRemotePath
    if binaryExists
      then liftIO $ LBS.readFile objectRemotePath
      else fail "Binary was not downloaded by engine"
