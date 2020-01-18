module Configuration where


import           Control.Applicative                      ( (<|>) )
import           Control.Arrow                            ( left )
import           Control.Monad.Except
import           Data.Carthage.Cartfile
import           Data.Carthage.TargetPlatform
import           Data.Yaml                                ( decodeFileEither
                                                          , prettyPrintParseException
                                                          )
import           Data.Monoid                              ( (<>) )
import           Data.Romefile
import qualified Data.Text.IO                  as T
import           System.Directory
import           System.FilePath


getCartfileEntries :: MonadIO m => ExceptT String m [CartfileEntry]
getCartfileEntries = do
  eitherCartfileEntries <- parseCartfileResolved cartfileResolved
  case eitherCartfileEntries of
    Left  e               -> throwError $ "Cartfile.resolved parse error: " ++ show e
    Right cartfileEntries -> return cartfileEntries

getRomefileEntries :: MonadIO m => FilePath -> ExceptT String m Romefile
getRomefileEntries absoluteRomefilePath =
  let fromYaml = ExceptT $ left prettyPrintParseException <$> (liftIO $ decodeFileEither absoluteRomefilePath)
      fromIni  = ExceptT $ parseRomefile <$> (liftIO $ T.readFile absoluteRomefilePath)
  in  withExceptT toErr $ fromYaml <|> fromIni
  where toErr e = "Error while parsing " <> absoluteRomefilePath <> ": " <> e

getAWSConfigFilePath :: MonadIO m => m FilePath
getAWSConfigFilePath = (</> awsConfigFilePath) `liftM` liftIO getHomeDirectory where awsConfigFilePath = ".aws/config"

getAWSCredentialsFilePath :: MonadIO m => m FilePath
getAWSCredentialsFilePath = (</> awsCredentialsFilePath) `liftM` liftIO getHomeDirectory
  where awsCredentialsFilePath = ".aws/credentials"

carthageBuildDirectory :: FilePath
carthageBuildDirectory = "Carthage" </> "Build"


-- | The Carthage build directory based on the `TargetPlatform` and the `FrameworkType`
--   from `Framework`. Ignores the `TargetPlatform` list in `Framework`
carthageArtifactsBuildDirectoryForPlatform :: TargetPlatform -> Framework -> FilePath
carthageArtifactsBuildDirectoryForPlatform platform (Framework _ Dynamic _) = carthageBuildDirectory </> show platform
carthageArtifactsBuildDirectoryForPlatform platform (Framework _ Static _) =
  carthageBuildDirectory </> show platform </> "Static"
