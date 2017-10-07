{-# LANGUAGE ExistentialQuantification #-}
{-# LANGUAGE OverloadedStrings         #-}

module Xcode.DWARF where


import           Control.Monad.Except
import           Data.Char            (toLower)
import           Data.List            (intercalate)
import qualified Data.Text            as T
import qualified Text.Parsec          as Parsec
import           Text.Read
import qualified Text.Read.Lex        as L
import qualified Turtle


-- Types

data Arch = ARMV7 | ARM64 | I386 | X86_64 | Other String deriving (Eq)

instance Show Arch where
 show ARMV7     = "armv7"
 show ARM64     = "arm64"
 show I386      = "i386"
 show X86_64    = "x86_64"
 show (Other s) = s

instance Read Arch where
 readPrec = parens $ do
   L.Ident s <- lexP
   case map toLower s of
      "armv7"  -> return ARMV7
      "arm64"  -> return ARM64
      "i386"   -> return I386
      "x86_64" -> return X86_64
      o        -> return $ Other o



data DwarfUUID = DwarfUUID { _uuid :: String
                           , _arch :: Arch
                           }
                           deriving (Show, Read, Eq)



-- Functions

-- | Attemps to get UUIDs of DWARFs form a .framework/<binary-name> or .dSYM
-- | by running `xcrun dwarfdump --uuid <path>`
dwarfUUIDs :: MonadIO m
           => FilePath -- ^ Path to dSYM or .framework/<binary-name>
           -> ExceptT String m [DwarfUUID]
dwarfUUIDs fPath = do
  (exitCode, stdOutText, stdErrText) <- Turtle.procStrictWithErr
    "xcrun" ["dwarfdump", "--uuid", T.pack fPath]
    (return $ Turtle.unsafeTextToLine "")
  case exitCode of
    Turtle.ExitSuccess -> either (throwError . (\e -> errorMessageHeader ++ show e)) return $
                            mapM (Parsec.parse parseDwarfdumpUUID "" . T.unpack) (T.lines stdOutText)
    _                  -> throwError $ errorMessageHeader ++ T.unpack stdErrText
  where
    errorMessageHeader = "Failed parsing DWARF UUID: "


--- UUID: EDF2AE8A-2EB4-3CA0-986F-D3E49D8C675F (i386) Carthage/Build/iOS/Alamofire.framework/Alamofire
parseDwarfdumpUUID :: Parsec.Parsec String () DwarfUUID
parseDwarfdumpUUID = do
  uuidSegments <- Parsec.string "UUID:"
    >> Parsec.spaces
    >> Parsec.manyTill (Parsec.many1 Parsec.hexDigit `Parsec.sepBy` Parsec.char '-') Parsec.space
  archString <- paren $ Parsec.many1 (Parsec.noneOf [')', ' ', '\t', '\n', '\r'])
  return DwarfUUID { _uuid = (intercalate "-" . concat) uuidSegments , _arch = read archString }
  where
    paren = Parsec.between (Parsec.char '(') (Parsec.char ')')
