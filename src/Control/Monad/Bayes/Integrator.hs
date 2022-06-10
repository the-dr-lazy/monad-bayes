{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}

-- |
-- This is adapted from https://jtobin.io/giry-monad-implementation
-- but brought into the monad-bayes framework (i.e. Integrator is an instance of MonadInfer)
-- It's largely for debugging other inference methods and didactic use, 
-- because brute force integration of measures is 
-- only practical for small programs


module Control.Monad.Bayes.Integrator 
  -- (probability,
  -- variance,
  -- expectation,
  -- cdf,
  -- empirical,
  -- enumerateWith,
  -- enumerateWithWeighted,
  -- histogram,
  -- plotCdf,
  -- volume,
  -- normalize,
  -- momentGeneratingFunction,
  -- cumulantGeneratingFunction,
  -- Integrator)
where

import Control.Monad.Trans.Cont
    ( cont, runCont, Cont, ContT(ContT) )
import Control.Monad.Bayes.Class (MonadSample (random, bernoulli, uniformD))
import Numeric.Integration.TanhSinh ( trap, Result(result) )
import Statistics.Distribution.Uniform qualified as Statistics
import Numeric.Log (Log(ln))
import Control.Monad.Bayes.Class (MonadCond (score), MonadInfer)
import Data.Set (Set, elems)
import Control.Foldl qualified as Foldl
import Control.Foldl (Fold)
import Control.Applicative (Applicative(..))
import Data.Foldable (Foldable(foldl'))
import Data.Text qualified as T
import Control.Monad.Bayes.Enumerator (compact, normalizeWeights)
import Statistics.Distribution (density)
import Control.Monad.Bayes.Weighted (Weighted, runWeighted)
import Data.Scientific (formatScientific, FPFormat (Exponent), fromFloatDigits)
import Debug.Trace (trace)


newtype Integrator a = Integrator {getCont :: Cont Double a}
  deriving newtype (Functor, Applicative, Monad)

runIntegrator :: (a -> Double) -> Integrator a -> Double
runIntegrator f (Integrator a) = runCont a f

instance MonadSample Integrator where
    random = fromDensityFunction $ density $ Statistics.uniformDistr 0 1
    bernoulli p = Integrator $ cont (\f -> p * f True + (1 -p) * f False)
    uniformD ls = fromMassFunction (const (1 / fromIntegral (length ls))) ls

fromDensityFunction :: (Double -> Double) -> Integrator Double
fromDensityFunction d = Integrator $ cont $ \f ->
    integralWithQuadrature (\x -> f x * d x)
  where
    integralWithQuadrature = result . last . (\z -> trap z 0 1)

fromMassFunction :: Foldable f => (a -> Double) -> f a -> Integrator a
fromMassFunction f support = Integrator $ cont \g ->
    foldl' (\acc x -> acc + f x * g x) 0 support

empirical :: Foldable f => f a -> Integrator a
empirical = Integrator . cont . flip weightedAverage where

    weightedAverage :: (Foldable f, Fractional r) => (a -> r) -> f a -> r
    weightedAverage f = Foldl.fold (weightedAverageFold f)

    weightedAverageFold :: Fractional r => (a -> r) -> Fold a r
    weightedAverageFold f = Foldl.premap f averageFold

    averageFold :: Fractional a => Fold a a
    averageFold = (/) <$> Foldl.sum <*> Foldl.genericLength

expectation :: Integrator Double -> Double
expectation = runIntegrator id

variance :: Integrator Double -> Double
variance nu = runIntegrator (^ 2) nu - expectation nu ^ 2

momentGeneratingFunction :: Integrator Double -> Double -> Double
momentGeneratingFunction nu t = runIntegrator (\x -> exp (t * x)) nu

cumulantGeneratingFunction :: Integrator Double -> Double -> Double
cumulantGeneratingFunction nu = log . momentGeneratingFunction nu

normalize :: Weighted Integrator a -> Integrator a
normalize m =
    let m' = runWeighted m
        z = runIntegrator (ln . exp . snd) m'
    in do
      (x, d) <- runWeighted m
      Integrator $ cont $ \f -> (f () * (ln $ exp d)) / z
      return x

cdf :: Integrator Double -> Double -> Double
cdf nu x = runIntegrator (negativeInfinity `to` x) nu where 

  negativeInfinity :: Double
  negativeInfinity = negate (1 / 0)

  to :: (Num a, Ord a) => a -> a -> a -> a
  to a b x
    | x >= a && x <= b = 1
    | otherwise        = 0

volume :: Integrator Double -> Double
volume = runIntegrator (const 1)

containing :: (Num a, Eq b) => [b] -> b -> a
containing xs x
  | x `elem` xs = 1
  | otherwise   = 0

instance Num a => Num (Integrator a) where
  (+)         = liftA2 (+)
  (-)         = liftA2 (-)
  (*)         = liftA2 (*)
  abs         = fmap abs
  signum      = fmap signum
  fromInteger = pure . fromInteger

probability :: Ord a => (a, a) -> Integrator a -> Double
probability (lower, upper) = runIntegrator (\x -> if x <upper && x  >= lower then 1 else 0)

enumerateWith :: Ord a => Set a -> Integrator a -> [(a, Double)]
enumerateWith ls meas = [(val, runIntegrator 
  (\x -> if x == val then 1 else 0) meas) 
  | val <- elems ls]

histogram :: (Enum a, RealFloat a) => 
  Int -> a -> Weighted Integrator a -> [(T.Text, Double)]
histogram nBins binSize model = do
    x <- take nBins [1..]
    let transform k = (k - (fromIntegral nBins / 2)) * binSize
    return (
      (T.pack . formatScientific Exponent (Just 2) . fromFloatDigits . fst) 
      (transform x,transform (x+1)), probability (transform x,transform (x+1)) $ normalize model)

plotCdf :: Int -> Double -> Integrator Double -> [(T.Text, Double)]
plotCdf nBins binSize model = do
    x <- take nBins [1..]
    let transform k = (k - (fromIntegral nBins / 2)) * binSize
    return ((T.pack . show) $  transform x, cdf model (transform x))
    