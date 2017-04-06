{-# LANGUAGE NamedFieldPuns  #-}
{-# LANGUAGE RecordWildCards #-}

module Data.Carthage.Cartfile
    ( parseCartfileResolved
    , cartfileResolved
    , CartfileEntry (..)
    , RepoHosting (..)
    , Version (..)
    , Location (..)
    ) where


import           Control.Applicative  ((<|>))
import           Control.Monad.Trans  (MonadIO, liftIO)
import           Data.Maybe
import qualified Text.Parsec          as Parsec
import qualified Text.Parsec.String   as Parsec
import qualified Text.Parsec.Utils    as Parsec

import           Data.Carthage.Common

newtype Location = Location { unLocation :: String }
                   deriving (Eq, Show, Ord)


data RepoHosting = GitHub | Git
  deriving (Eq, Show)

data CartfileEntry = CartfileEntry { hosting  :: RepoHosting
                                   , location :: Location
                                   , version  :: Version
                                   }
                                   deriving (Show, Eq)



cartfileResolved :: String
cartfileResolved = "Cartfile.resolved"

-- Cartfile.resolved parsing

parseGitHub :: Parsec.Parsec String () RepoHosting
parseGitHub = Parsec.string "github" >> Parsec.many1 Parsec.space >> pure GitHub

parseGit :: Parsec.Parsec String () RepoHosting
parseGit = Parsec.string "git" >> Parsec.many1 Parsec.space >> pure Git

repoHosting :: Parsec.Parsec String () RepoHosting
repoHosting = Parsec.try parseGit <|> parseGitHub

quotedContent :: Parsec.Parsec String () String
quotedContent = do
  Parsec.char '"'
  location <- Parsec.parseUnquotedString
  Parsec.char '"'
  return location

parseCartfileResolvedLine :: Parsec.Parsec String () CartfileEntry
parseCartfileResolvedLine = do
  hosting <- repoHosting
  location <- Location <$> quotedContent
  Parsec.many1 Parsec.space
  version <- Version <$> quotedContent
  return CartfileEntry {..}

parseMaybeCartfileEntry :: Parsec.Parsec String () (Maybe CartfileEntry)
parseMaybeCartfileEntry = Parsec.optional Parsec.spaces
                           *> (parseCartfileResolvedLine `Parsec.onceOrConsumeTill` Parsec.endOfLine)

parseCartfileResolved :: MonadIO m => String -> m (Either Parsec.ParseError [CartfileEntry])
parseCartfileResolved = liftIO . Parsec.parseFromFile (catMaybes <$> (parseMaybeCartfileEntry `Parsec.manyTill` Parsec.eof))
