module Data.Carthage.TargetPlatform where


import           Text.Read
import qualified Text.Read.Lex                 as L
import           Data.Char                                ( toLower )

data TargetPlatform = IOS | MacOS | TVOS | WatchOS
             deriving (Ord, Eq)

instance Show TargetPlatform where
  show IOS     = "iOS"
  show MacOS   = "Mac"
  show TVOS    = "tvOS"
  show WatchOS = "watchOS"

instance Read TargetPlatform where
  readPrec = parens $ do
    L.Ident s <- lexP
    case map toLower s of
      "ios"     -> return IOS
      "macos"   -> return MacOS
      "mac"     -> return MacOS
      "tvos"    -> return TVOS
      "watchos" -> return WatchOS
      a         -> error $ "Unrecognized platform " ++ a


allTargetPlatforms :: [TargetPlatform]
allTargetPlatforms = [IOS, MacOS, WatchOS, TVOS]
