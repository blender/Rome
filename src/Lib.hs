{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE NamedFieldPuns    #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}



{- Exports -}
module Lib
    ( parseRomeOptions
    , runRomeWithOptions
    , discoverRegion
    ) where



{- Imports -}
import qualified Codec.Archive.Zip            as Zip
import           Control.Applicative          ((<|>))
import           Control.Lens                 hiding (List)
import           Control.Monad
import           Control.Monad.Except
import           Control.Monad.Reader         (ReaderT, ask, runReaderT)
import           Control.Monad.Trans          (MonadIO, lift, liftIO)
import           Control.Monad.Trans.Resource (runResourceT)
import qualified Data.ByteString.Lazy         as L
import           Data.Cartfile
import           Data.Romefile
import           Data.Char                    (isSpace)
import           Data.Conduit.Binary          (sinkLbs)
import           Data.Ini                     as INI
import           Data.String.Utils
import qualified Data.Map                     as M
import           Data.Maybe
import qualified Data.Text                    as T
import qualified Network.AWS                  as AWS
import           Network.AWS.Data
import           Network.AWS.S3               as S3
import           Options.Applicative          as Opts
import           System.Directory
import           System.Environment



{- Types -}

type Config        = (AWS.Env, Bool)
type RomeMonad     = ExceptT String IO

data RomeCommand = Upload [FrameworkName]
                  | Download [FrameworkName]
                  | List ListMode
                  deriving (Show, Eq)

data ListMode = All
               | Missing
               | Present
               deriving (Show, Eq)

data RomeOptions = RomeOptions { romeCommand :: RomeCommand
                               , verbose     :: Bool
                               }



{- Functions -}
uploadParser :: Opts.Parser RomeCommand
uploadParser = pure Upload <*> Opts.many (Opts.argument str (Opts.metavar "FRAMEWORKS..." <> Opts.help "Zero or more framework names as specified in the Cartfile. If zero, all frameworks are uploaded."))

downloadParser :: Opts.Parser RomeCommand
downloadParser = pure Download <*> Opts.many (Opts.argument str (Opts.metavar "FRAMEWORKS..." <> Opts.help "Zero or more framework names as specified in the Cartfile. If zero, all frameworks are downloaded."))

listParser :: Opts.Parser RomeCommand
listParser = pure List <*> (
                            (Opts.flag' Missing (Opts.long "missing" <> Opts.help "List frameworks missing from the cache.")
                            <|> Opts.flag' Present (Opts.long "present" <> Opts.help "List frameworks present in the cache.")
                           )
                           <|> Opts.flag All All (Opts.help "Reports missing or present status of frameworks in the cache."))

parseRomeCommand :: Opts.Parser RomeCommand
parseRomeCommand = Opts.subparser $
  Opts.command "upload" (uploadParser `withInfo` "Uploads frameworks contained in the local Carthage/Build/iOS to S3, according to the local Cartfile.resolved")
  <> Opts.command "download" (downloadParser `withInfo` "Downloads and unpacks in Carthage/Build/iOS frameworks found in S3, according to the local Carftfile.resolved")
  <> Opts.command "list" (listParser `withInfo` "Lists frameworks in the cache and reports cache misses/hits, according to the local Carftfile.resolved")

parseRomeOptions :: Opts.Parser RomeOptions
parseRomeOptions = RomeOptions <$> parseRomeCommand <*> Opts.switch ( Opts.short 'v' <> help "Show verbose output" )

withInfo :: Opts.Parser a -> String -> Opts.ParserInfo a
withInfo opts desc = Opts.info (Opts.helper <*> opts) $ Opts.progDesc desc

getCartfileEntires :: RomeMonad [CartfileEntry]
getCartfileEntires = do
  eitherCartfileEntries <- liftIO $ parseCartfileResolved cartfileResolved
  case eitherCartfileEntries of
    Left e -> throwError $ "Carfile.resolved parse error: " ++ show e
    Right cartfileEntries -> return cartfileEntries

getRomefileEntries :: RomeMonad (S3.BucketName, [RomefileEntry])
getRomefileEntries = do
  romeConfig <- liftIO $ parseRomefile romefile
  case romeConfig of
    Left e -> throwError $ "Romefile parse error: " ++ show e
    Right (bucketName, entries) -> return (S3.BucketName $ T.pack bucketName, entries)

runRomeWithOptions :: AWS.Env -> RomeOptions -> ExceptT String IO ()
runRomeWithOptions env (RomeOptions options verbose) = do
  cartfileEntries <- getCartfileEntires
  (s3BucketName, romefileEntries) <- getRomefileEntries
  case options of
      Upload [] -> do
        let frameworkAndVersions = constructFrameworksAndVersionsFrom cartfileEntries romefileEntries
        liftIO $ runReaderT (uploadFrameworksToS3 s3BucketName frameworkAndVersions) (env, verbose)

      Upload names ->
        liftIO $ runReaderT (uploadFrameworksToS3 s3BucketName (filterByNames cartfileEntries romefileEntries names)) (env, verbose)

      Download [] -> do
        let frameworkAndVersions = constructFrameworksAndVersionsFrom cartfileEntries romefileEntries
        liftIO $ runReaderT (downloadFrameworksFromS3 s3BucketName frameworkAndVersions) (env, verbose)

      Download names ->
        liftIO $ runReaderT (downloadFrameworksFromS3 s3BucketName (filterByNames cartfileEntries romefileEntries names)) (env, verbose)

      List listMode -> do
        let frameworkAndVersions = constructFrameworksAndVersionsFrom cartfileEntries romefileEntries
        existing <- liftIO $ runReaderT (probeForFrameworks s3BucketName frameworkAndVersions) (env, verbose)
        let t = toInvertedRomeFilesEntriesMap romefileEntries
        let namesVersionAndExisting = replaceKnownFrameworkNamesWitGitRepoNamesInProbeResults (toInvertedRomeFilesEntriesMap romefileEntries) . filterAccordingToListMode listMode $  zip frameworkAndVersions existing
        liftIO $ mapM_ (printProbeResult listMode) namesVersionAndExisting

  where
    constructFrameworksAndVersionsFrom cartfileEntries romefileEntries = zip (deriveFrameworkNames (toRomeFilesEntriesMap romefileEntries) cartfileEntries) (map version cartfileEntries)
    filterByNames cartfileEntries romefileEntries = concatMap (constructFrameworksAndVersionsFrom cartfileEntries romefileEntries `filterByName`)

fromErrorMessage :: AWS.ErrorMessage -> String
fromErrorMessage (AWS.ErrorMessage t) = T.unpack t

filterByName:: [(FrameworkName, Version)] -> FrameworkName -> [(FrameworkName, Version)]
filterByName fs s = filter (\(name, version) -> name == s) fs

uploadFrameworksToS3 s3Bucket = mapM_ (uploadFrameworkToS3 s3Bucket)

uploadFrameworkToS3 s3BucketName (framework, version) = do
  let pathInCarthageBuild =  appendFrameworkExtensionTo $ "Carthage/Build/iOS/" ++ framework
  exists <- liftIO $ doesDirectoryExist pathInCarthageBuild
  when exists $ do
    (env, verbose) <- ask
    archive <- liftIO $ Zip.addFilesToArchive (zipOptions verbose) Zip.emptyArchive [pathInCarthageBuild]
    uploadBinary s3BucketName (Zip.fromArchive archive) (framework ++ "/" ++ appendFrameworkExtensionTo framework ++ "-" ++ version ++ ".zip") framework

uploadBinary s3BucketName binaryZip destinationPath frameworkName = do
  let objectKey = S3.ObjectKey $ T.pack destinationPath
  (env, verbose) <- ask
  runResourceT . AWS.runAWS env $ do
    let body = AWS.toBody binaryZip
    rs <- AWS.trying AWS._Error (AWS.send $ S3.putObject s3BucketName objectKey body)
    case rs of
      Left e -> sayLn $ "Error uploading " <> frameworkName <> " : " <> errorString e
      Right _ -> sayLn $ "Successfully uploaded " <> frameworkName <> " to: " <> destinationPath

downloadFrameworksFromS3 s3BucketName = mapM_ (downloadFrameworkFromS3 s3BucketName)

downloadFrameworkFromS3 s3BucketName (frameworkName, version) = do
  let frameworkZipName = frameworkArchiveName (frameworkName, version)
  let frameworkObjectKey = S3.ObjectKey . T.pack $ frameworkName ++ "/" ++ frameworkZipName
  (env, verbose) <- ask
  runResourceT . AWS.runAWS env $ getFramework s3BucketName frameworkObjectKey frameworkZipName verbose

getFramework s3BucketName frameworkObjectKey frameworkZipName verbose = do
  rs <- AWS.trying AWS._Error (AWS.send $ S3.getObject s3BucketName frameworkObjectKey)
  case rs of
    Left e -> sayLn $ "Error downloading " <> frameworkZipName <> " : " <> errorString e
    Right goResponse -> do
      lbs <- lift $ view S3.gorsBody goResponse `AWS.sinkBody` sinkLbs
      sayLn $ "Donwloaded: " ++ frameworkZipName
      liftIO $ Zip.extractFilesFromArchive (zipOptions verbose) (Zip.toArchive lbs)
      sayLn $ "Unzipped: " ++ frameworkZipName


probeForFrameworks s3BucketName = mapM (probeForFramework s3BucketName)

probeForFramework s3BucketName (frameworkName, version) = do
  let frameworkZipName = frameworkArchiveName (frameworkName, version)
  let frameworkObjectKey = S3.ObjectKey . T.pack $ frameworkName ++ "/" ++ frameworkZipName
  (env, verbose) <- ask
  runResourceT . AWS.runAWS env $ checkIfFrameworkExistsInBucket s3BucketName frameworkObjectKey verbose


checkIfFrameworkExistsInBucket s3BucketName frameworkObjectKey verbose = do
  rs <- AWS.trying AWS._Error (AWS.send $ S3.headObject s3BucketName frameworkObjectKey)
  case rs of
    Left e -> return False
    Right hoResponse -> return True

errorString :: AWS.Error -> String
errorString e = fromErrorMessage $ fromMaybe (AWS.ErrorMessage "Unexpected Error") maybeServiceError
  where
    maybeServiceError = view AWS.serviceMessage =<< (e ^? AWS._ServiceError)

sayLn :: MonadIO m => String -> m ()
sayLn = liftIO . putStrLn

zipOptions :: Bool -> [Zip.ZipOption]
zipOptions verbose = if verbose then [Zip.OptRecursive, Zip.OptVerbose] else [Zip.OptRecursive]

deriveFrameworkNames :: M.Map GitRepoName Version -> [CartfileEntry] -> [FrameworkName]
deriveFrameworkNames romeMap = map (deriveFrameworkName romeMap)

deriveFrameworkName ::  M.Map GitRepoName Version -> CartfileEntry -> FrameworkName
deriveFrameworkName romeMap (CartfileEntry GitHub l _) = fromMaybe gitHubRepositoryName (M.lookup gitHubRepositoryName romeMap)
  where
    gitHubRepositoryName = last $ splitWithSeparator '/' l
deriveFrameworkName romeMap (CartfileEntry Git l _)    = fromMaybe gitRepositoryName (M.lookup gitRepositoryName romeMap)
  where
    gitRepositoryName = getGitRepositoryNameFromGitURL l
    getGitRepositoryNameFromGitURL = replace ".git" "" . last . splitWithSeparator '/'

appendFrameworkExtensionTo :: FrameworkName -> String
appendFrameworkExtensionTo a = a ++ ".framework"

frameworkArchiveName :: (String, Version) -> String
frameworkArchiveName (name, version) = appendFrameworkExtensionTo name ++ "-" ++ version ++ ".zip"

splitWithSeparator :: (Eq a) => a -> [a] -> [[a]]
splitWithSeparator _ [] = []
splitWithSeparator a as = g as : splitWithSeparator a (dropTaken as as)
    where
      numberOfAsIn = length . takeWhile (== a)
      g = takeWhile (/= a) . dropWhile (== a)
      dropTaken bs = drop $ numberOfAsIn bs + length (g bs)

printProbeResult :: MonadIO m => ListMode -> ((String, Version), Bool) -> m ()
printProbeResult listMode ((frameworkName, version), present) | listMode == Missing || listMode ==  Present = sayLn frameworkName
                                                              | otherwise                                   = sayLn $ frameworkName <> " " <> version <> " " <> printProbeStringForBool present

printProbeStringForBool :: Bool -> String
printProbeStringForBool True  = green <> "✔︎" <> noColor
printProbeStringForBool False = red <> "✘" <> noColor

red :: String
red = "\ESC[0;31m"

green :: String
green = "\ESC[0;32m"

noColor :: String
noColor = "\ESC[0m"

filterAccordingToListMode :: ListMode -> [((String, Version), Bool)] -> [((String, Version), Bool)]
filterAccordingToListMode All probeResults     = probeResults
filterAccordingToListMode Missing probeResults = (\((name, version), present) -> not present) `filter`probeResults
filterAccordingToListMode Present probeResults = (\((name, version), present) -> present) `filter`probeResults

replaceKnownFrameworkNamesWitGitRepoNamesInProbeResults :: M.Map FrameworkName GitRepoName -> [((FrameworkName, Version), Bool)] -> [((String, Version), Bool)]
replaceKnownFrameworkNamesWitGitRepoNamesInProbeResults reverseRomeMap = map (replaceResultIfFrameworkNameIsInMap reverseRomeMap)
  where
    replaceResultIfFrameworkNameIsInMap reverseRomeMap ((frameworkName, version), present) = ((fromMaybe frameworkName (M.lookup frameworkName reverseRomeMap), version), present)


s3ConfigFile :: (MonadIO m) => m FilePath
s3ConfigFile = (++ p) `liftM` liftIO getHomeDirectory
    where
      p = "/.aws/config"

discoverRegion :: RomeMonad AWS.Region
discoverRegion = do
  f <- s3ConfigFile
  profile <- liftIO $ lookupEnv "AWS_PROFILE"
  getRegionFromFile f (fromMaybe "default" profile)

getRegionFromFile :: FilePath -> String -> RomeMonad AWS.Region
getRegionFromFile f profile = do
  i <- liftIO (INI.readIniFile f)
  case i of
    Left e -> throwError e
    Right ini -> do
      regionString <- req "region" ini
      case (fromText regionString :: Either String AWS.Region) of
        Left e  -> throwError e
        Right r -> return r
  where
  blank x = T.null x || T.all isSpace x

  req k i =
      case INI.lookupValue (T.pack profile) k i of
          Left  e         -> invalidErr (Just $ T.unpack k) e
          Right x
              | blank x   -> invalidErr (Just $ T.unpack k) "cannot be a blank string."
              | otherwise -> return x

  opt k i = return $
      case INI.lookupValue (T.pack profile) k i of
          Left  _ -> Nothing
          Right x -> Just x

  invalidErr Nothing  e = throwError e
  invalidErr (Just k) e = throwError $ f <> ", key " <> k <> " " <> e

toRomeFilesEntriesMap :: [RomefileEntry] -> M.Map String String
toRomeFilesEntriesMap = M.fromList . map romeFileEntryToTuple

toInvertedRomeFilesEntriesMap :: [RomefileEntry] -> M.Map String String
toInvertedRomeFilesEntriesMap = M.fromList . map ( uncurry (flip (,)) . romeFileEntryToTuple)

romeFileEntryToTuple :: RomefileEntry -> (String, String)
romeFileEntryToTuple RomefileEntry {..} = (gitRepositoryName, frameworkCommonName)
