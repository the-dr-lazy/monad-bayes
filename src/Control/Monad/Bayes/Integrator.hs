{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DerivingStrategies #-}

-- |
-- This is heavily inspired by https://jtobin.io/giry-monad-implementation
-- but brought into the monad-bayes framework (i.e. Measure is an inference transformer)
-- It's largely for debugging other inference methods and didactic use, 
-- because brute force integration of measures is 
-- only practical for small programs


module Control.Monad.Bayes.Integrator where

import Control.Monad.Trans.Cont
    ( cont, runCont, Cont, ContT(ContT) )
import Control.Monad.Bayes.Class (MonadSample (random, bernoulli, normal, uniformD), condition)
import Statistics.Distribution (density)
import Numeric.Integration.TanhSinh
    ( trap, Result(result) )
import Control.Monad.Bayes.Weighted (runWeighted, Weighted)
import qualified Statistics.Distribution.Uniform as Statistics
import Numeric.Log (Log(ln))
import Data.Set (Set, fromList, elems)
import qualified Control.Foldl as Foldl
import Control.Foldl (Fold)
import Control.Applicative (Applicative(..))
import qualified Control.Monad.Bayes.Enumerator as Enumerator
import Data.Foldable (Foldable(foldl'))


newtype Integrator a = Integrator (Cont Double a) 
  deriving newtype (Functor, Applicative, Monad)

runIntegrator :: (a -> Double) -> Integrator a -> Double
runIntegrator f (Integrator a) = runCont a f

instance MonadSample Integrator where
    random = fromDensityFunction $ density $ Statistics.uniformDistr 0 1
    bernoulli p = Integrator $ cont (\f -> p * f True + (1 -p) * f False)
    uniformD = fromMassFunction (const 1)

fromDensityFunction :: (Double -> Double) -> Integrator Double
fromDensityFunction d = Integrator $ cont $ \f ->
    integralWithQuadrature (\x -> f x * d x)
  where
    integralWithQuadrature = result . last . (\z -> trap z 0 1)

fromMassFunction :: Foldable f => (a -> Double) -> f a -> Integrator a
fromMassFunction f support = Integrator $ cont \g ->
    foldl' (\acc x -> acc + f x * g x) 0 support

empirical :: Foldable f => f a -> Integrator a
empirical = Integrator . ContT . flip weightedAverage where

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

probability :: Ord a => (a, a) -> Weighted Integrator a -> Double
probability (lower, upper) = runIntegrator (\(x,d) -> if x<upper && x  > lower then exp $ ln d else 0) . runWeighted


enumerate :: Ord a => Set a -> Weighted Integrator a -> Either String [(a, Double)]
enumerate ls meas =
    -- let norm = expectation $ exp . ln . snd <$> runWeighted meas
    Enumerator.empirical [(val, runIntegrator (\(x,d) ->
            if x == val
                then exp (ln d)
                else 0)
                (runWeighted meas)) | val <- elems ls]



example :: Either String [(Bool, Double)]
example = enumerate (fromList [True, False]) $ do

    x <- normal 0 1
    y <- bernoulli x
    condition (not y)
    return (x > 0)


-- TODO: function to make an integrator from a sampling functor