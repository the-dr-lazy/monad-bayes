{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}

-- |
-- This is heavily inspired by https://jtobin.io/giry-monad-implementation
-- but brought into the monad-bayes framework (i.e. Measure is an instance of MonadInfer)
-- It's largely for debugging other inference methods and didactic use, 
-- because brute force integration of measures is 
-- only practical for small programs


module Control.Monad.Bayes.Integrator 
  (probability,
  variance,
  expectation,
  cdf,
  empirical,
  enumerateWith,
  histogram,
  plotCdf,
  volume,
  normalize,
  Integrator)
where

import Control.Monad.Trans.Cont
    ( cont, runCont, Cont, ContT(ContT), mapCont )
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

normalize :: Weighted Integrator Double -> Integrator Double
normalize m =
    let m' = runWeighted m
        z = runIntegrator (ln . exp . snd) m'
    in fmap (\(x, w) -> x * (ln (exp w)/z)) m'

cdf :: Integrator Double -> Double -> Double
cdf nu x = runIntegrator (negativeInfinity `to` x) nu

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

enumerateWith :: Ord a => Set a -> Weighted Integrator a -> [(a, Double)]
enumerateWith ls meas =
    let norm = volume $ exp . ln . snd <$> runWeighted meas
    in normalizeWeights $ compact [(val, runIntegrator (\(x,d) ->
            if x == val
                then ln (exp d) / norm
                else 0)
                (runWeighted meas)) | val <- elems ls]

histogram :: (Enum a, Show a, Ord a, Fractional a) => 
  Int -> a -> Integrator a -> [(T.Text, Double)]
histogram nBins binSize model = do
    x <- take nBins [1..]
    let transform k = (k - (fromIntegral nBins / 2)) * binSize
    return ((T.pack . show) (transform x,transform (x+1)),probability (transform x,transform (x+1)) model)

plotCdf :: Int -> Double -> Integrator Double -> [(T.Text, Double)]
plotCdf nBins binSize model = do
    x <- take nBins [1..]
    let transform k = (k - (fromIntegral nBins / 2)) * binSize
    return ((T.pack . show) $  transform x, cdf model (transform x))
    