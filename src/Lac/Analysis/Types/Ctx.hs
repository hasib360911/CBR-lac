{-# LANGUAGE RecordWildCards #-}

module Lac.Analysis.Types.Ctx where

import           Data.Type
import           Lac.Analysis.Types.Coeff

import           Data.Map.Strict          (Map)
import           Data.Map.Strict          as M
import           Data.Text                (Text)
import           Data.Text                as T

data Ctx
  = Ctx {
    -- | Context identifier, i.e. 2 for context @Q_2@
    ctxId           :: Int
    -- | Coefficients in context
    -- | Variables in context
  , ctxCoefficients :: Map Idx Coeff
  , ctxVariables    :: Map Text Type
  }
  deriving (Eq, Show)

latexCtx :: Ctx -> Text
latexCtx Ctx{..} = "Q_{" <> T.pack (show ctxId) <> "}"

ctxEmpty :: Ctx -> Bool
ctxEmpty Ctx{..} = M.null ctxVariables

data Idx
  = AstIdx
  | IdIdx Text
  | VecIdx [Int]
  deriving (Eq, Ord, Show)
