{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}

module Lac.TypeInference where

import           Data.Expr.Typed
import           Data.Expr.Types
import           Data.Term
import           Data.Type

import           Control.Monad                  (replicateM)
import           Control.Monad.State.Strict.Ext
import           Data.List                      (find)
import qualified Data.List.NonEmpty             as NE
import           Data.Maybe                     (fromJust, fromMaybe)
import           Data.Text                      (Text)
import qualified Data.Text                      as T

-- type inference

type Env = [(T String Text, Type)]

tyBool :: Type
tyBool = F "Bool" []

tyNat :: Type
tyNat = F "Nat" []

tyTree :: Type
tyTree = F "Tree" [tyNat]

tyFun :: Type -> Type -> Type
tyFun a b = F "->" [a, b]

class Typable a where
  infer :: (Env, a, Type) -> State Int ([(Type, Type)], Typed)

instance Typable Expr where
  infer = inferExprType

inferExprType :: (Env, Expr, Type) -> State Int ([(Type, Type)], Typed)
inferExprType (env, expr, tau) =
  case expr of
    Lit LNil -> return ([(tau, tyTree)], TyLit (TyLNil, tau))
    Lit (LNode e1 e2 e3) -> do
      (xs, e1') <- infer (env, e1, tyTree)
      (ys, e2') <- infer (env, e2, tyNat)
      (zs, e3') <- infer (env, e3, tyTree)
      let eqs = (tau, tyTree) : concat [xs, ys, zs]
      return (eqs, (TyLit (TyLNode (e1', tyTree) (e2', tyNat) (e3', tyTree), tau)))
    Lit (LBool True) -> return ([(tau, tyBool)], TyLit (TyLBool True, tau))
    Lit (LBool False) -> return ([(tau, tyBool)], TyLit (TyLBool False, tau))
    Lit (LNat n) -> return ([(tau, tyNat)], TyLit (TyLNat n, tau))
    Var x ->
      let p ((V y), _ ) = x == y
          p _           = False
      in
      case find p env of
        Just (_, ty) ->
          return ([(tau, ty)], TyVar x)
        Nothing ->
          error . T.unpack $ "unbound variable: `" <> x <> "`"
        {-
        Nothing -> do
          a <- fresh
          return [(tau, V a)]
        -}
    App e1 e2 -> do
      a <- fresh
      let funTy = F "->" [V a, tau]
      let argTy = V a
      (xs, e1') <- infer (env, e1, funTy)
      (ys, e2') <- infer (env, e2, argTy)
      return (xs ++ ys, TyApp (e1', funTy) (e2', argTy))
    Abs x e -> do
      a1 <- fresh
      a2 <- fresh
      let env' = (V x, V a1) : env
      let ty = V a2
      (xs, e') <- infer (env', e, ty)
      return ((tau, F "->" [V a1, ty]) : xs, TyAbs x (e', ty))
    Let x e1 e2 -> do
      a <- fresh
      let env' = (V x, V a) : env
      (xs, e1') <- infer (env, e1, V a)
      (ys, e2') <- infer (env', e2, tau)
      return (xs ++ ys, TyLet x (e1', V a) (e2', tau))
    Ite e1 e2 e3 -> do
      (xs, e1') <- infer (env, e1, tyBool)
      (ys, e2') <- infer (env, e2, tau)
      (zs, e3') <- infer (env, e3, tau)
      return (concat [xs, ys, zs], TyIte (e1', tyBool) (e2', tau) (e3', tau))
    Match e es ->
      do
        (xs, e') <- infer (env, e, tyTree)
        temp <- mapM f es
        let ys = concat . NE.map fst $ temp
        let es' = NE.map snd temp
        return (xs ++ ys, TyMatch (e', tyTree) es')
      where
        f (p, e) =
          case p of
            PNil -> do
              (cs, e') <- infer (env, e, tau)
              return (cs, (PNil, (e', tau)))
            PNode l x r -> do
              let env' = (V l, tyTree) : (V x, tyNat) : (V r, tyTree) : env
              (cs, e') <- infer (env', e, tau)
              return (cs, (PNode l x r, (e', tau)))
    Cmp op e1 e2 -> do
      a <- fresh
      (xs, e1') <- infer (env, e1, V a)
      (ys, e2') <- infer (env, e2, V a)
      let eqs = (tau, tyBool) : (xs ++ ys)
      return (eqs, TyCmp op (e1', V a) (e1', V a))

mkProgEnv :: Env -> [Decl] -> State Int [((T String Text, Type), Expr)]
mkProgEnv env decls =
  do
    as <- replicateM (length decls) fresh
    return $ zipWith f decls as
  where
    f decl@(Decl name xs e) a = ((V name, V a), fromDecl xs e)

extractEnv :: Env -> [((T String Text, Type), Expr)] -> Env
extractEnv env decls' = map fst decls' ++ env

inferProgType' :: (Env, Program, Type) -> State Int [(Type, Type)]
inferProgType' (env, Program decls, tau) =
  do
    decls' <- mkProgEnv env decls
    let env' = extractEnv env decls'
    let obtainConstraints = concat . map fst
    obtainConstraints <$> mapM (\((_, a), e) -> infer (env', e, a)) decls'

inferProgType :: Env -> Program -> ([(Type, Type)], Int)
inferProgType env prog = runState (inferProgType' (env, prog, V 0)) 0

inferType :: Typable a => Env -> a -> ([(Type, Type)], Int)
inferType env expr =
  let ((constraints, _typed), n) = runState (infer (env, expr, V 0)) 0
  in
  (constraints, n)

typed :: Env -> Expr -> Maybe (Typed, Type)
typed env expr =
  let ((eqs, varExpr), _) = runState (inferExprType (env, expr, V 0)) 0
  in
  case unify eqs of
    Left _      -> Nothing
    Right subst ->
      let typedExpr = applySubst subst varExpr
      in
      Just (typedExpr, fromJust (lookup (V 0) subst))

applySubst :: [(Type, Type)] -> Typed -> Typed
applySubst subst =
  \case
    TyLit (l, ty) -> TyLit (l, lookup' ty)
    TyVar x -> TyVar x
    TyCmp op (e1, ty1) (e2, ty2) -> TyCmp op (rec e1, lookup' ty1) (rec e2, lookup' ty2)
    TyIte (e1, ty1) (e2, ty2) (e3, ty3) -> TyIte (rec e1, lookup' ty1) (rec e2, lookup' ty2) (rec e3, lookup' ty3)
    TyLet x (e1, ty1) (e2, ty2) -> TyLet x (rec e1, lookup' ty1) (rec e2, lookup' ty2)
    TyApp (e1, ty1) (e2, ty2) -> TyApp (rec e1, lookup' ty1) (rec e2, lookup' ty2)
    TyMatch (e, t) cs -> TyMatch (rec e, lookup' t) (NE.map f cs)
      where
        f (p, (e, ty)) = (p, (rec e, lookup' ty))
    TyAbs x (e, ty) -> TyAbs x (rec e, lookup' ty)
  where
    lookup' k =
      case k of
        V x    -> fromJust (lookup (V x) subst)
                  -- fromMaybe k (lookup k subst)
        F f ts -> F f (map lookup' ts)
    rec = applySubst subst
