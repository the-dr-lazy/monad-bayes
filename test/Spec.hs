{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE Trustworthy #-}

import Test.Hspec (context, describe, hspec, it, shouldBe)
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (ioProperty, (==>))
import TestDistribution qualified
import TestEnumerator qualified
import TestInference qualified
import TestPopulation qualified
import TestSequential qualified
import TestWeighted qualified

main :: IO ()
main = hspec $ do
  describe "Distribution" $
    it "gives correct covariance" $
      do
        let passed = TestDistribution.passed1
        passed `shouldBe` True
  describe "Weighted" $
    it "accumulates likelihood correctly" $
      do
        passed <- TestWeighted.passed
        passed `shouldBe` True
  describe "Enumerator" $ do
    it "sorts samples and aggregates weights" $
      TestEnumerator.passed2 `shouldBe` True
    it "gives correct answer for the sprinkler model" $
      TestEnumerator.passed3 `shouldBe` True
    it "computes expectation correctly" $
      TestEnumerator.passed4 `shouldBe` True
  describe "Population" $ do
    context "controlling population" $ do
      it "preserves the population when not explicitly altered" $ do
        popSize <- TestPopulation.popSize
        popSize `shouldBe` 5
      it "multiplies the number of samples when spawn invoked twice" $ do
        manySize <- TestPopulation.manySize
        manySize `shouldBe` 15
      it "correctly computes population average" $
        TestPopulation.popAvgCheck `shouldBe` True
    context "distribution-preserving transformations" $ do
      it "collapse preserves the distribution" $ do
        TestPopulation.transCheck1 `shouldBe` True
        TestPopulation.transCheck2 `shouldBe` True
      it "resample preserves the distribution" $ do
        TestPopulation.resampleCheck 1 `shouldBe` True
        TestPopulation.resampleCheck 2 `shouldBe` True
  describe "Sequential" $ do
    it "stops at every factor" $ do
      TestSequential.checkTwoSync 0 `shouldBe` True
      TestSequential.checkTwoSync 1 `shouldBe` True
      TestSequential.checkTwoSync 2 `shouldBe` True
    it "preserves the distribution" $
      TestSequential.checkPreserve `shouldBe` True
    it "produces correct intermediate weights" $ do
      TestSequential.checkSync 0 `shouldBe` True
      TestSequential.checkSync 1 `shouldBe` True
      TestSequential.checkSync 2 `shouldBe` True
  describe "SMC" $ do
    it "terminates" $
      seq TestInference.checkTerminateSMC () `shouldBe` ()
    it "preserves the distribution on the sprinkler model" $
      TestInference.checkPreserveSMC `shouldBe` True
    prop "number of particles is equal to its second parameter" $
      \observations particles ->
        observations >= 0 && particles >= 1 ==> ioProperty $ do
          checkParticles <- TestInference.checkParticles observations particles
          return $ checkParticles == particles
  describe "SMC with systematic resampling" $
    prop "number of particles is equal to its second parameter" $
      \observations particles ->
        observations >= 0 && particles >= 1 ==> ioProperty $ do
          checkParticles <- TestInference.checkParticlesSystematic observations particles
          return $ checkParticles == particles

  describe "SMC with stratified resampling" $
    prop "number of particles is equal to its second parameter" $
      \observations particles ->
        observations >= 0 && particles >= 1 ==> ioProperty $ do
          checkParticles <- TestInference.checkParticlesStratified observations particles
          return $ checkParticles == particles
