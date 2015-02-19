{-# LANGUAGE MultiParamTypeClasses, FlexibleContexts, DefaultSignatures,
             DeriveDataTypeable, GADTs, Rank2Types #-}
{-# OPTIONS -Wall -Werror #-}

module Language.Hakaru.Syntax (Real, Prob, Measure, Vector,
       EqType(Refl), Order_(..), Number(..), Fraction(..),
       Uneither(Uneither),
       errorEmpty,
       Order(..), Base(..), ununit, fst_, snd_, swap_,
       and_, or_, not_, min_, max_, lesseq,
       sumVec, normalizeVector, dirichlet,
       lengthV, mapWithIndex, mapV, zipWithV, zipV, incV,
       Mochastic(..), bind_, factor, weight, bindx, liftM, liftM2,
       categorical',mix',
       invgamma, exponential, chi2, bern,
       cauchy, laplace, student, weibull,
       binomial, multinomial,
       Integrate(..), Lambda(..), Lub(..)) where

import Data.Typeable (Typeable)    
import Prelude hiding (Real)

infix  4 `less`, `equal`, `less_`, `equal_`
infixl 1 `bind`, `bind_`, `bindx`
infixl 9 `app`

------- Types

data Real      deriving Typeable
data Prob      deriving Typeable -- meaning: non-negative real number
data Measure a deriving Typeable
data Vector a  deriving Typeable -- TODO: rename to something like Array

data EqType t t' where
  Refl :: EqType t t

class Order_ a where
  less_, equal_  :: (Base repr              ) => repr a -> repr a -> repr Bool
  default less_  :: (Base repr, Order repr a) => repr a -> repr a -> repr Bool
  default equal_ :: (Base repr, Order repr a) => repr a -> repr a -> repr Bool
  less_  = less
  equal_ = equal

instance Order_ Int
instance Order_ Real
instance Order_ Prob

instance Order_ () where
  less_  _ _ = false
  equal_ _ _ = true

instance Order_ Bool where
  less_  x y = if_ x false y
  equal_ x y = if_ x y (not_ y)

instance (Order_ a, Order_ b) => Order_ (a, b) where
  less_  ab1 ab2 = unpair ab1 (\a1 b1 ->
                   unpair ab2 (\a2 b2 ->
                   or_ [less_ a1 a2, and_ [equal_ a1 a2, less_ b1 b2]]))
  equal_ ab1 ab2 = unpair ab1 (\a1 b1 ->
                   unpair ab2 (\a2 b2 ->
                   and_ [equal_ a1 a2, equal_ b1 b2]))

instance (Order_ a, Order_ b) => Order_ (Either a b) where
  less_  ab1 ab2 = uneither ab1
                     (\a1 -> uneither ab2 (\a2 -> less_ a1 a2) (\_ -> true))
                     (\b1 -> uneither ab2 (\_ -> false) (\b2 -> less_ b1 b2))
  equal_ ab1 ab2 = uneither ab1
                     (\a1 -> uneither ab2 (\a2 -> equal_ a1 a2) (\_ -> false))
                     (\b1 -> uneither ab2 (\_ -> false) (\b2 -> equal_ b1 b2))

instance (Order_ a) => Order_ (Vector a) where
  less_ _ _ = undefined
  equal_ _ _ = undefined

class (Order_ a) => Number a where
  numberCase :: f Int -> f Real -> f Prob -> f a
  numberRepr :: (Base repr) =>
                ((Order repr a, Num (repr a)) => f repr a) -> f repr a

class (Number a) => Fraction a where
  fractionCase :: f Real -> f Prob -> f a
  fractionRepr :: (Base repr) =>
                  ((Order repr a, Fractional (repr a)) => f repr a) -> f repr a
  unsafeProbFraction :: (Base repr) => repr a -> repr Prob
  piFraction         :: (Base repr) => repr a
  expFraction        :: (Base repr) => repr Real -> repr a
  logFraction        :: (Base repr) => repr a -> repr Real
  erfFraction        :: (Base repr) => repr a -> repr a

instance Number Int where
  numberCase k _ _ = k
  numberRepr k     = k

instance Number Real where
  numberCase _ k _ = k
  numberRepr k     = k

instance Number Prob where
  numberCase _ _ k = k
  numberRepr k     = k

instance Fraction Real where
  fractionCase k _ = k
  fractionRepr k   = k
  unsafeProbFraction = unsafeProb
  piFraction         = pi
  expFraction        = exp
  logFraction        = log
  erfFraction        = erf

instance Fraction Prob where
  fractionCase _ k = k
  fractionRepr k   = k
  unsafeProbFraction = id
  piFraction         = pi_
  expFraction        = exp_
  logFraction        = log_
  erfFraction        = erf_

newtype Uneither repr a b = Uneither (forall c.
  repr (Either a b) -> (repr a -> repr c) -> (repr b -> repr c) -> repr c)

------- Terms

class (Number a) => Order repr a where
  less          ::                repr a -> repr a -> repr Bool
  equal         ::                repr a -> repr a -> repr Bool
  default equal :: (Base repr) => repr a -> repr a -> repr Bool
  equal a b = not_ (or_ [less a b, less b a])

class (Order repr Int , Num        (repr Int ),
       Order repr Real, Floating   (repr Real),
       Order repr Prob, Fractional (repr Prob)) => Base repr where
  unit       :: repr ()
  pair       :: repr a -> repr b -> repr (a,b)
  unpair     :: repr (a,b) -> (repr a -> repr b -> repr c) -> repr c
  inl        :: repr a -> repr (Either a b)
  inr        :: repr b -> repr (Either a b)
  uneither   :: repr (Either a b) ->
                (repr a -> repr c) -> (repr b -> repr c) -> repr c
  true       :: repr Bool
  false      :: repr Bool
  if_        :: repr Bool -> repr c -> repr c -> repr c

  nil        :: repr [a]
  cons       :: repr a -> repr [a] -> repr [a]
  unlist     :: repr [a] -> repr c ->
                (repr a -> repr [a] -> repr c) -> repr c

  unsafeProb :: repr Real -> repr Prob
  fromProb   :: repr Prob -> repr Real
  fromInt    :: repr Int  -> repr Real

  pi_      :: repr Prob
  pi_      =  unsafeProb pi
  exp_     :: repr Real -> repr Prob
  exp_     =  unsafeProb . exp
  erf      :: repr Real -> repr Real
  erf_     :: repr Prob -> repr Prob
  erf_     =  unsafeProb . erf . fromProb
  log_     :: repr Prob -> repr Real
  log_     =  log . fromProb
  sqrt_    :: repr Prob -> repr Prob
  sqrt_ x  =  pow_ x (1/2)
  pow_     :: repr Prob -> repr Real -> repr Prob
  pow_ x y =  exp_ (log_ x * y)

  infinity, negativeInfinity :: repr Real

  gammaFunc         ::                     repr Real -> repr Prob
  default gammaFunc :: (Integrate repr) => repr Real -> repr Prob
  gammaFunc t = integrate 0 infinity $ \x ->
    pow_ (unsafeProb x) (t-1) * exp_ (-x)

  betaFunc         ::                     repr Prob -> repr Prob -> repr Prob
  default betaFunc :: (Integrate repr) => repr Prob -> repr Prob -> repr Prob
  betaFunc a b = integrate 0 1 $ \x -> pow_ (unsafeProb x    ) (fromProb a - 1)
                                     * pow_ (unsafeProb (1-x)) (fromProb b - 1)

  vector           :: repr Int -> repr Int ->
                      (repr Int -> repr a) -> repr (Vector a)
  empty            :: repr (Vector a)
  index            :: repr (Vector a) -> repr Int -> repr a
  loBound, hiBound :: repr (Vector a) -> repr Int
  reduce           :: (repr a -> repr a -> repr a) ->
                      repr a -> repr (Vector a) -> repr a
  vector           =  error "vector unimplemented"
  empty            =  error "empty unimplemented"
  index            =  error "index unimplemented"
  loBound          =  error "loBound unimplemented"
  hiBound          =  error "hiBound unimplemented"
  reduce           =  error "reduce unimplemented"
  
  fix :: (repr a -> repr a) -> repr a
  fix f = x where x = f x

ununit :: repr () -> repr a -> repr a
ununit _ e = e

fst_ :: (Base repr) => repr (a,b) -> repr a
fst_ ab = unpair ab (\a _ -> a)

snd_ :: (Base repr) => repr (a,b) -> repr b
snd_ ab = unpair ab (\_ b -> b)

swap_ :: (Base repr) => repr (a,b) -> repr (b,a)
swap_ ab = unpair ab (flip pair)

and_ :: (Base repr) => [repr Bool] -> repr Bool
and_ []     = true
and_ [b]    = b
and_ (b:bs) = if_ b (and_ bs) false

or_ :: (Base repr) => [repr Bool] -> repr Bool
or_ []      = false
or_ [b]     = b
or_ (b:bs)  = if_ b true (or_ bs)

not_ :: (Base repr) => repr Bool -> repr Bool
not_ a = if_ a false true

min_, max_ :: (Order_ a, Base repr) => repr a -> repr a -> repr a
min_ x y = if_ (less_ x y) x y
max_ x y = if_ (less_ x y) y x

lesseq :: (Order repr a, Base repr) => repr a -> repr a -> repr Bool
lesseq x y = or_ [(less x y) , (equal x y)]

class (Base repr) => Mochastic repr where
  dirac         :: repr a -> repr (Measure a)
  bind          :: repr (Measure a) ->
                   (repr a -> repr (Measure b)) -> repr (Measure b)
  lebesgue      :: repr (Measure Real)
  counting      :: repr (Measure Int)
  superpose     :: [(repr Prob, repr (Measure a))] -> repr (Measure a)

  uniform       :: repr Real -> repr Real -> repr (Measure Real)
  uniform lo hi =  lebesgue `bind` \x ->
                   if_ (and_ [less lo x, less x hi])
                       (superpose [(recip (unsafeProb (hi - lo)), dirac x)])
                       (superpose [])
  normal        :: repr Real -> repr Prob -> repr (Measure Real)
  normal mu sd  =  lebesgue `bind` \x ->
                   superpose [( exp_ (- (x - mu)^(2::Int)
                                      / fromProb (2 * pow_ sd 2))
                                 / sd / sqrt_ (2 * pi_)
                              , dirac x )]
  categorical   :: repr (Vector Prob) -> repr (Measure Int)

  poisson       :: repr Prob -> repr (Measure Int)
  poisson l     =  counting `bind` \x ->
                   if_ (and_ [not_ (less x 0), less 0 l])
                       (superpose [( pow_ l (fromInt x)
                                   / gammaFunc (fromInt x + 1)
                                   / exp_ (fromProb l)
                                   , dirac x )])
                       (superpose [])

  gamma :: repr Prob -> repr Prob -> repr (Measure Prob)
  gamma shape scale =
    lebesgue `bind` \x ->
    if_ (less 0 x)
        (let x_ = unsafeProb x
             shape_ = fromProb shape in
         superpose [(pow_ x_ (fromProb (shape - 1))
                    * exp_ (- fromProb (x_ / scale))
                    / (pow_ scale shape_ * gammaFunc shape_),
                    dirac (unsafeProb x))])
        (superpose [])

  beta :: repr Prob -> repr Prob -> repr (Measure Prob)
  beta a b = uniform 0 1 `bind` \x ->
             superpose [( pow_ (unsafeProb x    ) (fromProb a - 1)
                        * pow_ (unsafeProb (1-x)) (fromProb b - 1)
                        / betaFunc a b
                        , dirac (unsafeProb x) )]

  dp :: repr Prob -> repr (Measure a) -> repr (Measure (Measure a))
  dp =  error "dp unimplemented"

  plate :: repr (Vector (     Measure         a   )) ->
           repr (             Measure (Vector a   ))
  chain :: (Lambda repr) =>
           repr (Vector (s -> Measure        (a,s))) ->
           repr (        s -> Measure (Vector a, s))
  plate v = reduce r z (mapWithIndex m v)
    where r     = liftM2 concatV
          z     = dirac empty
          m i a = liftM (vector i i . const) a
  chain v = reduce r z (mapWithIndex m v)
    where r x y = lam (\s -> app x s `bind` \v1s1 ->
                             unpair v1s1 $ \v1 s1 ->
                             app y s1 `bind` \v2s2 ->
                             unpair v2s2 $ \v2 s2 ->
                             dirac (pair (concatV v1 v2) s2))
          z     = lam (\s -> dirac (pair empty s))
          m i a = lam (\s -> liftM (`unpair` pair . vector i i . const)
                                   (app a s))

errorEmpty :: a
errorEmpty = error "empty mixture makes no sense"

bind_ :: (Mochastic repr) => repr (Measure a) -> repr (Measure b) ->
                                                 repr (Measure b)
m `bind_` n = m `bind` \_ -> n

factor :: (Mochastic repr) => repr Prob -> repr (Measure ())
factor p = weight p (dirac unit)

weight :: (Mochastic repr) => repr Prob -> repr (Measure w) -> repr (Measure w)
weight p m = superpose [(p, m)]

mix' :: (Mochastic repr) => [(repr Prob, repr (Measure a))] -> repr (Measure a)
mix' []        =  errorEmpty
mix' pms       =  let total = sum (map fst pms)
                  in superpose [ (p/total, m) | (p,m) <- pms ]

categorical' :: (Mochastic repr) =>[(repr Prob, repr a)] -> repr (Measure a)
categorical' l =  mix' [ (p, dirac x) | (p,x) <- l ]


bindx :: (Mochastic repr) => repr (Measure a) ->
         (repr a -> repr (Measure b)) -> repr (Measure (a,b))
m `bindx` k = m `bind` \a -> k a `bind` \b -> dirac (pair a b)

liftM :: (Mochastic repr) => (repr a -> repr b) ->
         repr (Measure a) -> repr (Measure b)
liftM f m = m `bind` dirac . f

liftM2 :: (Mochastic repr) => (repr a -> repr b -> repr c) ->
          repr (Measure a) -> repr (Measure b) -> repr (Measure c)
liftM2 f m n = m `bind` \x -> n `bind` \y -> dirac (f x y)

invgamma :: (Mochastic repr) => repr Prob -> repr Prob -> repr (Measure Prob)
invgamma k t = liftM recip (gamma k (recip t))

exponential :: (Mochastic repr) => repr Prob -> repr (Measure Prob)
exponential l = gamma 1 l

chi2 :: (Mochastic repr) => repr Prob -> repr (Measure Prob)
chi2 v = gamma (v/2) 2

cauchy :: (Mochastic repr) => repr Real -> repr Prob -> repr (Measure Real)
cauchy loc scale = normal 0 1 `bind` \x ->
                   normal 0 1 `bind` \y ->
                   dirac $ loc + (fromProb scale)*(x/y)

laplace :: (Mochastic repr) => repr Real -> repr Prob -> repr (Measure Real)
laplace loc scale = exponential 1 `bind` \v ->
                    normal 0 1 `bind` \z ->
                    dirac $ loc + z*(fromProb $ scale*sqrt_(2*v))

student :: (Mochastic repr) => repr Real -> repr Prob -> repr (Measure Real)
student loc v = normal loc 1 `bind` \z ->
                chi2 v `bind` \df ->
                dirac $ z*(fromProb $ sqrt_ (v/df))

weibull :: (Mochastic repr) => repr Prob -> repr Prob -> repr (Measure Prob)
weibull b k = exponential 1 `bind` \x ->
              dirac $ b*(pow_ x (fromProb $ recip k))

bern :: (Mochastic repr) => repr Prob -> repr (Measure Bool)
bern p = categorical' [(p, true), (1-p, false)]

class (Base repr) => Integrate repr where
  integrate :: repr Real -> repr Real -> (repr Real -> repr Prob) -> repr Prob
  summate   :: repr Real -> repr Real -> (repr Int  -> repr Prob) -> repr Prob

sumVec :: Integrate repr => repr (Vector Prob) -> repr Prob
sumVec x = summate (fromInt $ loBound x)
                   (fromInt $ hiBound x)
                   (\ i -> index x i)

binomial :: (Mochastic repr) =>
            repr Int -> repr Prob -> repr (Measure Int)
binomial n p = (plate $ vector 1 n (\ _ -> bern p `bind` \x ->
                                   dirac $ if_ x 1 0)) `bind` \trials ->
               dirac (reduce (+) 0 trials)

multinomial :: (Mochastic repr) => repr Int -> repr (Vector Prob) ->
                                    repr (Measure (Vector Prob))
multinomial n v = reduce (liftM2 $ zipWithV (+))
                          (dirac $ constV v 0)
                          (vector 0 (n-1) (\ _ ->
                           categorical v `bind` \i ->
                           dirac (unitV v i)))

unNormedDirichlet :: Mochastic repr =>
                     repr (Vector Prob) -> repr (Measure (Vector Prob))
unNormedDirichlet a = plate $ vector (loBound a)
                                     (hiBound a)
                                     (\ i -> gamma (index a i) 1)

normalizeVector :: (Integrate repr, Lambda repr) =>
                    repr (Vector Prob) -> repr (Vector Prob)
normalizeVector x = let_ (sumVec x) (\ normalized ->
                    vector (loBound x)
                           (hiBound x)
                           (\ i -> index x i / normalized))

dirichlet :: (Lambda repr, Mochastic repr, Integrate repr) =>
              repr (Vector Prob) -> repr (Measure (Vector Prob))
dirichlet a = unNormedDirichlet a `bind` \xs ->
              dirac (normalizeVector xs)                    

incV :: Base repr => repr (Vector a) -> repr (Vector Int)
incV v = vector (loBound v) (hiBound v) id

constV :: Base repr => repr (Vector a) -> repr b -> repr (Vector b)
constV v c = vector (loBound v) (hiBound v) (const c)

unitV :: Base repr => repr (Vector a) -> repr Int -> repr (Vector Prob)
unitV v i = vector (loBound v) (hiBound v)
            (\ i' -> if_ (equal i i') 1 0)

lengthV :: (Base repr) => repr (Vector a) -> repr Int
lengthV v = hiBound v - loBound v + 1

concatV :: (Base repr) => repr (Vector a) -> repr (Vector a) -> repr (Vector a)
concatV v1 v2 = vector (loBound v1) (hiBound v1 + lengthV v2)
  (\i -> if_ (less (hiBound v1) i)
             (index v2 (i - hiBound v1 - 1 + loBound v2))
             (index v1 i))

mapWithIndex :: (Base repr) => (repr Int -> repr a -> repr b)
             -> repr (Vector a) -> repr (Vector b)
mapWithIndex f v = vector (loBound v) (hiBound v)
                   (\i -> f i (index v i))

mapV :: (Base repr) => (repr a -> repr b)
     -> repr (Vector a) -> repr (Vector b)
mapV f = mapWithIndex (const f)
        
-- | Assume (without checking) that the bounds of the two
-- vectors are the same
zipWithV :: (Base repr) => (repr a -> repr b -> repr c)
         -> repr (Vector a) -> repr (Vector b) -> repr (Vector c)
zipWithV f v1 v2 = vector (loBound v1) (hiBound v1)
                   (\i -> f (index v1 i) (index v2 i))

zipV :: (Base repr) => repr (Vector a) -> repr (Vector b)
     -> repr (Vector (a,b))
zipV = zipWithV pair

class Lambda repr where
  lam :: (repr a -> repr b) -> repr (a -> b)
  app :: repr (a -> b) -> repr a -> repr b
  let_ :: (Lambda repr) => repr a -> (repr a -> repr b) -> repr b
  let_ x f = lam f `app` x

class Lub repr where
  lub :: repr a -> repr a -> repr a -- two ways to compute the same thing
  bot :: repr a -- no way to compute anything (left and right identity for lub)
