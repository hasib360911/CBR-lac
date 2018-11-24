{-# LANGUAGE LambdaCase #-}

module Main where

import           Data.Expr
import           Lac.Eval
import           Lac.Inf

import           Control.Monad          (forM_, void, when)
import           Control.Monad.State    (StateT, get)
import           Control.Monad.Trans    (liftIO)
import           Data.Map               (Map)
import qualified Data.Map               as M
import           Data.Text              (Text)
import qualified Data.Text              as T
import qualified Data.Text.IO           as T
import           System.Environment.Ext
import qualified System.Repl            as Repl
import           Text.Parsec            (many1, parse)

data ReplState
  = ReplState {
    rsEnv   :: Map Text Expr
  , rsFlags :: [String]
  }
  deriving (Eq, Show)

defaultReplState :: ReplState
defaultReplState = ReplState mempty mempty

main :: IO ()
main = do
  (flags, args) <- partitionArgs <$> getArgs
  forM_ args $ \arg -> do
    r <- parse (many1 decl) arg <$> T.readFile arg
    case r of
      Left e -> print e
      Right decls ->
        do
          let env = M.fromList . map (\(Decl x xs e) -> (x, fromDecl xs e)) $ decls
          let rs = defaultReplState {
                rsEnv = env
              , rsFlags = flags
              }
          repl rs

fromDecl :: [Text] -> Expr -> Expr
fromDecl (x:xs) e = Abs x (fromDecl xs e)
fromDecl [] e = e

repl :: ReplState -> IO ()
repl s =
  void $ Repl.repl "> " s $
    \case
      ':' : cmd -> command cmd
      line      -> input line
  where
    command :: String -> StateT ReplState IO Bool
    command "quit" = return False
    command "decls" = rsFlags <$> get >>= go
      where
        go :: [String] -> StateT ReplState IO Bool
        go flags =
          do
            decls <- (map select . M.toList . rsEnv) <$> get
            mapM_ (liftIO . f) decls
            when ("--inf" `elem` flags) $
              forM_ decls $ \(Decl _ _ e) ->
                liftIO (print (inferType mempty e))
            return True
          where
            select (name, e) = Decl name [] e

            f | "--ast" `elem` flags = print
              | otherwise            = T.putStrLn . pretty
    command _ = do
      liftIO $ putStrLn "unknown command"
      return True

    input :: String -> StateT ReplState IO Bool
    input line = do
      case parse expr mempty (T.pack line) of
        Left e -> liftIO $ print e
        Right e -> do
          env <- rsEnv <$> get
          flags <- rsFlags <$> get
          liftIO $ do
            when ("--ast" `elem` flags) (print e)
            when ("--inf" `elem` flags) (print (inferType mempty e))
            T.putStrLn . pretty $ eval env e
      return True
