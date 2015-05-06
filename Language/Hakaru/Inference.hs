{-# LANGUAGE TypeFamilies, RankNTypes, FlexibleContexts #-}
module Language.Hakaru.Inference where

import Prelude hiding (Real)

import Language.Hakaru.Lazy
import Language.Hakaru.Compose
import Language.Hakaru.Syntax
import Language.Hakaru.Expect (Expect(..), Expect', normalize)

priorAsProposal :: Mochastic repr =>
                   repr (Measure (a,b)) -> repr (a,b) -> repr (Measure (a,b))
priorAsProposal p x = bern (1/2) `bind` \c ->
                      p `bind` \x' ->
                      dirac (if_ c
                             (pair (fst_ x ) (snd_ x'))
                             (pair (fst_ x') (snd_ x )))

mh :: (Mochastic repr, Integrate repr, Lambda repr,
       a ~ Expect' a, Order_ a, Backward a a) =>
      (forall repr'. (Mochastic repr') => repr' a -> repr' (Measure a)) ->
      (forall repr'. (Mochastic repr') => repr' (Measure a)) ->
      repr (a -> Measure (a, Prob))
mh proposal target =
  let_ (lam (d unit)) $ \mu ->
  lam $ \old ->
    proposal old `bind` \new ->
    dirac (pair new (mu `app` pair new old / mu `app` pair old new))
  where d:_ = density (\dummy -> ununit dummy $ bindx target proposal)

mcmc :: (Mochastic repr, Integrate repr, Lambda repr,
         a ~ Expect' a, Order_ a, Backward a a) =>
        (forall repr'. (Mochastic repr') => repr' a -> repr' (Measure a)) ->
        (forall repr'. (Mochastic repr') => repr' (Measure a)) ->
        repr (a -> Measure a)
mcmc proposal target =
  let_ (mh proposal target) $ \f ->
  lam $ \old ->
    app f old `bind` \new_ratio ->
    unpair new_ratio $ \new ratio ->
    bern (min_ 1 ratio) `bind` \accept ->
    dirac (if_ accept new old)

gibbsProposal :: (Expect' a ~ a, Expect' b ~ b,
                  Backward a a, Order_ a, 
                  Mochastic repr, Integrate repr, Lambda repr) =>
                 Cond (Expect repr) () (Measure (a,b)) ->
                 repr (a, b) -> repr (Measure (a, b))
gibbsProposal p x = q (fst_ x) `bind` \x' -> dirac (pair (fst_ x) x')
  where d:_ = runDisintegrate p
        q y = normalize (app (app d unit) (Expect y))              

-- Slice sampling can be thought of:
--
-- slice target x = do
--      u  <- uniform(0, density(target, x))  
--      x' <- lebesgue
--      condition (density(target, x') >= u) true
--      return x'

slice :: (Mochastic repr, Integrate repr, Lambda repr) =>
         (forall s t. Lazy s (Compose [] t (Expect repr))
                             (Measure Real)) ->
         repr (Real -> Measure Real)
slice target = lam $ \x ->
               uniform 0 (densAt x) `bind` \u ->
               lebesgue `bind` \x' ->
               if_ (u `less_` densAt x')
                 (dirac x')
                 (superpose [])
  where d:_ = density (\dummy -> ununit dummy target)
        densAt x = fromProb $ d unit x

incompleteBeta :: Integrate repr => repr Prob -> repr Prob -> repr Prob -> repr Prob
incompleteBeta x a b = integrate 0 (fromProb x)
                       (\t -> pow_ (unsafeProb t    ) (fromProb a-1) *
                              pow_ (unsafeProb $ 1-t) (fromProb b-1))

regBeta :: Integrate repr => repr Prob -> repr Prob -> repr Prob -> repr Prob
regBeta x a b = incompleteBeta x a b / betaFunc a b

tCDF :: Integrate repr => repr Real -> repr Prob -> repr Prob
tCDF x v = 1 - (1/2)*regBeta (v / (unsafeProb (x*x) + v)) (v/2) (1/2)

approxMh :: (Mochastic repr, Integrate repr, Lambda repr) =>
            repr (a -> Measure (a, Prob))
approxMh = undefined