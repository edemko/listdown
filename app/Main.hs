{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE OverloadedRecordDot #-}
{-# LANGUAGE OverloadedStrings #-}

module Main where

import Security
import Urls

import Config (Config(..), getConfig)
import Control.Monad.IO.Class (liftIO)
import Data.List (sort)
import Listdown (runParser,fromTextFile,toTextFile)
import System.Directory (doesDirectoryExist,createDirectoryIfMissing,listDirectory)
import System.Directory (doesFileExist)
import System.FilePath ((</>),takeDirectory)
import Web.Scotty (ActionM,get,post)
import Web.Scotty (scotty)

import qualified Data.ByteString.Lazy as LBS
import qualified Data.Text.IO as T
import qualified Data.Text.Lazy as LT
import qualified Data.Text.Lazy.Encoding as LT
import qualified Data.Text.Lazy.IO as LT
import qualified Html.Dir as Html
import qualified Html.List as Html
import qualified Lucid as Lucid
import qualified Network.HTTP.Types as Http
import qualified Web.Scotty as Scotty

main :: IO ()
main = do
  config <- getConfig
  scotty config.port $ do
    ------ Lists ------
    get listDirR $ do
      let user = Me :: User 'Authd -- TODO
      target <- listDirP
      authListDirReadPerm config user target >>= \case
        Nothing -> Scotty.raiseStatus Http.status403 $ "not authorized"
        Just (Left permit) -> getDir permit
        Just (Right permit) -> getList permit
    post listDirR $ do
      let user = Me :: User 'Authd -- TODO
      target <- listP
      authListDirWritePerm config user target >>= \case
        Nothing -> Scotty.raiseStatus Http.status403 $ "not authorized"
        Just (Left permit) -> putDir permit
        Just (Right permit) -> putList permit
    get listR $ do
      let user = Me :: User 'Authd -- TODO
      target <- listP
      permit <- case authListReadPerm config user target of
        Nothing -> Scotty.raiseStatus Http.status403 $ "not authorized"
        Just permit -> pure permit
      getList permit
    post listR $ do
      let user = Me :: User 'Authd -- TODO
      target <- listP
      permit <- case authListWritePerm config user target of
        Nothing -> Scotty.raiseStatus Http.status403 $ "not authorized"
        Just permit -> pure permit
      putList permit
    ------ Directories ------
    get dirR $ do
      let user = Me :: User 'Authd -- TODO
      target <- dirP
      permit <- case authDirReadPerm config user target of
        Nothing -> Scotty.raiseStatus Http.status403 $ "not authorized"
        Just permit -> pure permit
      getDir permit
    post dirR $ do
      let user = Me :: User 'Authd -- TODO
      target <- dirP
      permit <- case authDirWritePerm config user target of
        Nothing -> Scotty.raiseStatus Http.status403 $ "not authorized"
        Just permit -> pure permit
      putDir permit
    ------ Static Files ------
    get "/static/:file" $ do
      file <- Scotty.param "file"
      contentType <-
        if | ".css" `LT.isSuffixOf` file -> pure "text/css"
           | ".js" `LT.isSuffixOf` file -> pure "text/javascript"
           | otherwise -> Scotty.raiseStatus Http.status404 "no such file"
      Scotty.setHeader "Content-Type" contentType
      let filename = config.staticDir </> LT.unpack file
      content <- liftIO $ LT.readFile filename
      Scotty.text content
    get (Scotty.regex "^/(.*favicon.*)$") $ do
      file <- Scotty.param "1"
      let filename = config.staticDir </> "favicon" </> LT.unpack file
      Scotty.setHeader "Content-Type" "image.png"
      content <- liftIO $ LBS.readFile filename
      Scotty.raw content

------------ Handlers ------------

------ Lists ------

doesListExist :: Permit 'Read 'ForList -> ActionM Bool
doesListExist permit = liftIO $ doesFileExist permit.filepath

getList :: Permit 'Read 'ForList -> ActionM ()
getList permit = do
  txt <- doesListExist permit >>= \case
    False -> pure ""
    True -> liftIO $ T.readFile permit.filepath
  case runParser $ fromTextFile txt of
    Left err -> Scotty.raiseStatus Http.status500 $
      "corrupt list: " <> (LT.pack . show) err
    Right ld -> do
      let html = Lucid.renderText $ Html.listHtml (listParentReadPerm permit) ld
      Scotty.html html

putList :: Permit 'Write 'ForList -> ActionM ()
putList permit = do
  ld <- Scotty.param "body" >>= \body -> case LT.decodeUtf8' body of
    Left err -> Scotty.raiseStatus Http.status400 $
      "invalid utf8: " <> (LT.pack . show) err
    Right txt -> case runParser (fromTextFile (LT.toStrict txt)) of
      Left err -> Scotty.raiseStatus Http.status400 $
        "bad listdown syntax: " <> (LT.pack . show) err
      Right ld -> pure ld
  liftIO $ do
    createDirectoryIfMissing True (takeDirectory permit.filepath)
    T.writeFile permit.filepath (toTextFile ld)
  getList (demotePermsWriteToRead permit)

------ Directories ------

doesDirExist :: Permit a 'ForDir -> ActionM Bool
doesDirExist permit = liftIO $ doesDirectoryExist permit.filepath

getDir :: Permit 'Read 'ForDir -> ActionM ()
getDir permit = do
  children0 <- doesDirExist permit >>= \case
    False -> Scotty.raiseStatus Http.status404 "no such directory"
    True -> liftIO $ listDirectory permit.filepath
  let children = sort children0
  Scotty.html $ Lucid.renderText $
    Html.directoryList permit children

putDir :: Permit 'Write 'ForDir -> ActionM ()
putDir permit = do
  liftIO $ createDirectoryIfMissing True (permit.filepath)
  getDir (demotePermsWriteToRead permit)
