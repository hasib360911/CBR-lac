{-# LANGUAGE RecordWildCards #-}

module Data.TypeAnn.TypeAnn where

import           Data.Type

import           Data.Text (Text)

data TypeAnn
  = TypeAnn {
    taSym :: Text
  , taArg :: [Type]
  , taAnn :: ([Int], [([Int], Int)])
  }
  deriving (Eq, Show)

rankCoeffs :: TypeAnn -> [Int]
rankCoeffs = fst . taAnn

vecCoeffs :: TypeAnn -> [([Int], Int)]
vecCoeffs = snd . taAnn

isBaseTypeAnn :: TypeAnn -> Bool
isBaseTypeAnn TypeAnn{..} = all isBaseType taArg