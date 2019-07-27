{-# LANGUAGE OverloadedStrings #-}
module Main where

import Tests.Utils
import qualified Tests.Test1 as Test1

main :: IO ()
main = runTestsEx [
    (Test1.test "42;", 42),
    (Test1.test "1+2;", 3),
    (Test1.test "1+2+4;", 7),
    (Test1.test "10-7+3;", 6),
    (Test1.test "42+23-30;", 35),
    (Test1.test "42/2+2-5;", 18),
    (Test1.test "(3+5)/2;", 4),
    (Test1.test "(4-2)*8+20/4;",21),
    (Test1.test "-(-3*+5);", 15),
    (Test1.test "-25+30;", 5),
    (Test1.test "42 == 42;", 1),
    (Test1.test "42 != 53;", 1),
    (Test1.test "42 < 53;", 1),
    (Test1.test "53 > 42;", 1),
    (Test1.test "42 <= 42;", 1),
    (Test1.test "32 <= 42;", 1),
    (Test1.test "42 >= 42;", 1),
    (Test1.test "53 >= 42;", 1),
    (Test1.test "(1 + 1) == 2;", 1),
    (Test1.test "(2 * 3) != 2;", 1),
    (Test1.test "a=42; b=20; a+b;", 62),
    (Test1.test "a=42; b=20; c=32; (a - c) * b / 10;", 20),
    (Test1.test "hoge=42; foo=20; hoge - foo;", 22),
    (Test1.test "hoge=42; return hoge;", 42),
    (Test1.test "returnx = 42; return returnx; return 53;", 42),
    (Test1.test "a = 3; b = 5 * 6 - 8; return a + b / 2;", 14),
    (Test1.test "if (1) return 42; return 53;", 42),
    (Test1.test "if (20*3-60) return 42; return 53;", 53),
    (Test1.test "a = 1; b = 2; if (a) return b; return 42;", 2),
    (Test1.test "if (1) return 42; else return 53;", 42),
    (Test1.test "if (0) return 42; else return 53;", 53),
    (Test1.test "a = 0; b = 2; if (a) return b; else return b * 2;", 4),
    (Test1.test "a = 1; b = 0; if (b) return 42; if (0) return 42; else return a;", 1),
    (Test1.test "a = 1; b = 2; if (a) if (b) return b; else return 53; else return 24;", 2),
    (Test1.test "if (1) if (1) if (1) if (1) if (1) if (0) return 1; else return 2; else return 3; else return 4; else return 5; else return 6; else return 7;", 2),
    (Test1.test "if(1)if(1)return 42;return 53;", 42),
    (Test1.test "if(0); return 0;", 0),
    (Test1.test "a = 1; while (a < 10) a = a + 1; return a;", 10),
    (Test1.test "a = 1; while (a < 10) a = a + 1; b = 1; while (b < 20) b = b + 2; return a + b;", 31),
    (Test1.test "a = 0; while (a); return 0;", 0),
    (Test1.test "a = 0; for (i = 1; i <= 10; i = i + 1) a = a + i * 2; return a;", 110),
    (Test1.test "i = 0; for (; i <= 10;) i = i + 2; return i;", 12),
    (Test1.test "i = 0; for (; i <= 10; i = i + 2);  return i;", 12),
    (Test1.test "a = 0; for (i = 0; i < 10; i = i + 1) if (a) a = 0; else a = 1; return a;", 0)
    ]
