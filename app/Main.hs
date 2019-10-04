module Main where

import System.Environment (getArgs)
import System.Exit (exitFailure)
import Data.Bool (bool)
-- import qualified Data.Text.Lazy.IO as T
import qualified Data.Text as T
import Data.Tuple.Extra (second, dupe)

import Htcc.Asm.Generate (casm)

checkArgs :: IO (Maybe [String])
checkArgs = uncurry (bool Nothing . Just) . second (not . null) . dupe <$> getArgs

maybeExit :: Maybe a -> IO a
maybeExit = maybe exitFailure return

main :: IO ()
main = checkArgs >>= maybeExit >>= casm . T.pack . head
