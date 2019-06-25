{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

module Main where

import           Data.Bound
import           Data.Expr                  hiding (fromDecl)
import           Data.Expr.Typed
import           Data.Term
import           Data.Type
import           Lac
import           Lac.Analysis.Rules
import           Lac.Analysis.Types         (augmentCtx, rootCtx, runGen)
import           Lac.Eval
import           Lac.TypeInference

import           Control.Monad              (forM_, void, when)
import           Control.Monad.State.Strict (StateT, get)
import           Control.Monad.Trans        (liftIO)
import           Data.List                  (isPrefixOf)
import           Data.Map                   (Map)
import qualified Data.Map                   as M
import           Data.Monoid                ((<>))
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.IO               as T
import           System.Environment.Ext
import qualified System.Repl                as Repl
import           Text.Parsec                (parse)

main :: IO ()
main = do
  (flags, args) <- partitionArgs <$> getArgs
  forM_ args $ \arg -> do
    r <- readProg arg
    case r of
      Left e -> print e
      Right Prog{..} ->
        do
          let rs = defaultReplState {
                rsEnv = progEnv
              , rsFlags = flags
              }
          repl rs

data ReplState
  = ReplState {
    rsEnv   :: Map Text Value
  , rsFlags :: [String]
  }
  deriving (Eq, Show)

defaultReplState :: ReplState
defaultReplState = ReplState mempty mempty

repl :: ReplState -> IO ()
repl s =
  void $ Repl.repl "> " s $
    \case
      ':' : cmd -> command cmd
      line      -> input line
  where
    command :: String -> StateT ReplState IO Bool
    command i | i `isPrefixOf` "help" = do
      forM_ commands $ \(n, ReplCmd{..}) ->
        liftIO $
          T.putStrLn $ ":" <> T.pack n <> " - " <> replCmdDesc (T.pack n)
      return True
    command i =
      case match commands i of
        Right ReplCmd{..} -> replCmdFunc mempty
        Left e            -> liftIO (print e) >> return True

    input :: String -> StateT ReplState IO Bool
    input line = do
      case parse expr mempty (T.pack line) of
        Left e -> liftIO $ print e
        Right e -> do
          env <- rsEnv <$> get
          flags <- rsFlags <$> get
          liftIO $ do
            when ("--ast" `elem` flags) (print e)
            T.putStrLn . pretty . toExpr $ eval env env e
      return True

data ReplErr
  = ReplErr Text
  deriving (Eq, Show)

data ReplCmd
  = ReplCmd {
    replCmdName :: String
  , replCmdFunc :: [String] -> StateT ReplState IO Bool
  , replCmdDesc :: Text -> Text
  }

match :: [(String, ReplCmd)] -> String -> Either ReplErr ReplCmd
match cs i =
  case filter (\(n, _) -> i `isPrefixOf` n) cs of
    [(_,c)]  -> Right c
    []       -> Left (ReplErr "no match")
    xs@(_:_) -> Left (ReplErr $ "ambiguous match: " <> T.intercalate ", " (map (T.pack . fst) xs))

commands :: [(String, ReplCmd)]
commands = map (\cmd@ReplCmd{..} -> (replCmdName, cmd)) [cmdQuit, cmdDecls, cmdCheck]

cmdQuit :: ReplCmd
cmdQuit = ReplCmd "quit" (const $ return False) (const "quit program")

cmdDecls :: ReplCmd
cmdDecls = ReplCmd "decls" cmd (const "show loaded declarations")
  where
    cmd _ = rsFlags <$> get >>= go
      where
        go :: [String] -> StateT ReplState IO Bool
        go flags =
          do
            decls <- getTypedProgram
            forM_ decls $ \(f, _, (e, ty)) ->
              liftIO $ T.putStrLn $ f <> " : " <> ppTerm' ty
            return True

splitDecl :: Typed -> ([(Text, Type)], Typed)
splitDecl e = go [] e
  where
    go acc (TyAbs (x, tx) (e, te)) =
      let acc' = (x, tx) : acc
      in
      case e of
        TyAbs _ _ -> go acc' e
        _         -> (reverse acc', e)
    go _ _ = error "decl"

cmdCheck :: ReplCmd
cmdCheck = ReplCmd "check" cmd (const "infer constraints for loaded program")
  where
    cmd :: [String] -> StateT ReplState IO Bool
    cmd _ =
      do
        decls <- getTypedProgram
        forM_ decls $ \(f, _, (e, ty)) -> do
          -- TODO: add declarations to context
          liftIO $ do
            ctx' <- runGen $ do
              let (xs, e') = splitDecl e
              q <- augmentCtx (Bound 1) rootCtx xs
              dispatch q e'
            print ctx'
        return True

getTypedProgram :: StateT ReplState IO [(Text, [Text], (Typed, Type))]
getTypedProgram =
  do
    decls <- (map select . M.toList . rsEnv) <$> get
    let program = Program decls
    return $ inferProgType program
  where
    select (name, e) = Decl name [] (toExpr e)
