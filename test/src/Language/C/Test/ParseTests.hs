{-# LANGUAGE FlexibleContexts #-} 
{-# OPTIONS  #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  ParseTests
-- Copyright   :  (c) 2008 Benedikt Huber
-- License     :  BSD-style
-- Maintainer  :  benedikt.huber@gmail.com
-- Portability :  non-portable
--
-- Provides a set of tests for the parser and pretty printer.
-----------------------------------------------------------------------------
module Language.C.Test.ParseTests (
-- * Misc helpers
time, lineCount, withFileExt,
-- * preprocessing
runCPP,
-- * Tests
parseTestTemplate, runParseTest,
ppTestTemplate, runPrettyPrint,
equivTestTemplate,runEquivTest,
) where
import Control.Monad.State
import Control.Monad.Instances
import Data.List

import System.Cmd
import System.Directory 
import System.Exit
import System.FilePath (takeBaseName)
import System.IO

import Language.C
import Language.C.Toolkit.Position

import Language.C.Test.Environment
import Language.C.Test.Framework
import Language.C.Test.GenericAST
import Language.C.Test.TestMonad

-- ===================
-- = Misc            =
-- ===================

lineCount :: FilePath -> IO Int
lineCount = liftM (length . lines) . readFile

-- | change filename extension
withFileExt :: FilePath -> String -> FilePath
withFileExt filename ext = (stripExt filename) ++ "." ++ ext where
  stripExt fn = 
    let basefn = takeBaseName fn in
    case (dropWhile (/= '.') . reverse) basefn of
      ('.' : s : ss) -> reverse (s : ss)
      _ -> basefn

-- =======
-- = CPP =
-- =======
  
-- | @(copiedFile,preprocessedFile) = runTestCPP origFile cppArgs@ copies the original 
--   file to @copiedFile@ and then preprocesses this file using @gcc -E -o preprocessedFile cppArgs@. 
runCPP :: FilePath -> [String] -> TestMonad (FilePath,FilePath)      
runCPP origFile cppArgs = do
  -- copy original file (for reporting)
  cFile <- withTempFile ".c" $ \_ -> return ()
  copySuccess <- liftIOCatched (copyFile origFile cFile)
  case copySuccess of
    Left err -> errorOnInit cppArgs $ "Copy failed: " ++ show err
    Right () -> dbgMsg      $ "Copy: " ++ origFile ++ " ==> " ++ cFile ++ "\n"
  
  -- preprocess C file, if it isn't preprocessed already
  preFile <- case isPreprocessedFile cFile of
    False -> do
      dbgMsg $ "Preprocessing " ++ origFile ++ "\n"
      preFile     <- withTempFile ".i" $ \_hnd -> return ()
      gccExitcode <- liftIO $ rawSystem "gcc" (["-E", "-o", preFile] ++ cppArgs ++ [cFile])
      case gccExitcode of 
        ExitSuccess       ->  do
          modify $ addTmpFile preFile
          return preFile
        ExitFailure fCode ->
          errorOnInit cppArgs $ "C preprocessor failed: " ++ "`gcc -E -o " ++ preFile ++ " " ++ origFile ++ 
                                "' returned exit code `" ++ show fCode ++ "'"
    True -> return cFile
  return (cFile,preFile)

-- ===============
-- = Parse tests =
-- ===============

parseTestTemplate :: Test
parseTestTemplate = Test
  {
    testName = "parse",
    testDescr = "parse the given preprocessed c file",
    preferredScale = Kilo,
    inputUnit = linesOfCode
  }

runParseTest :: FilePath           -- ^ preprocesed file
             -> Position           -- ^ initial position
             -> TestMonad (Either (String,FilePath) (CHeader,PerfMeasure)) -- ^ either (errMsg,reportFile) (ast,(locs,elapsedTime))
runParseTest preFile initialPos = do
  -- parse
  dbgMsg $ "Starting Parse of " ++ preFile ++ "\n"
  ((parse,input),elapsed) <-
    time $ do input <- liftIO$ readFile preFile
              parse <- parseEval input initialPos
              return (parse,input)

  -- check error and add test
  dbgMsg $ "Parse result : " ++ eitherStatus parse ++ "\n"
  case parse of
    Left err@(errMsgs, pos) -> do
      report <- reportParseError err input
      return $ Left $ (unlines (("Parse error in " ++ show pos) : errMsgs), report)
    Right header -> 
      return $ Right $ (header,PerfMeasure (locsOf input,elapsed))

reportParseError :: ([String],Position) -> String -> TestMonad FilePath
reportParseError (errMsgs,pos) input = do
  withTempFile ".report" $ \hnd -> liftIO $ do
    pwd        <- getCurrentDirectory
    contextMsg <- getContextInfo pos
    hPutStr hnd $ "Failed to parse " ++ (posFile pos)
               ++ "\nwith message:\n" ++ concat errMsgs ++ " " ++ show pos
               ++ "\n" ++ contextMsg
               ++ "\nWorking dir: " ++ pwd
               ++ "\nPreprocessed input follows:\n\n" ++ input

-- ======================
-- = Pretty print tests =
-- ======================
ppTestTemplate :: Test
ppTestTemplate = Test
  {
    testName = "pretty-print",
    testDescr = "pretty-print the given AST",
    preferredScale = Kilo,
    inputUnit = linesOfCode
  }

runPrettyPrint :: CHeader -> TestMonad ((FilePath, FilePath), PerfMeasure)
runPrettyPrint ast = do
    -- pretty print
    dbgMsg "Pretty Print ..."
    (fullExport,t) <-
      time $
        withTempFile "pp.c" $ \hnd -> 
          liftIO $ hPutStrLn hnd $ show (pretty ast)
    modify $ addTmpFile fullExport
    locs <- liftIO $ lineCount fullExport

    dbgMsg $ " to " ++ fullExport ++ " (" ++ show locs ++ " lines)"++ "\n"
    
    -- export the parsed file, with headers via include
    dbgMsg $ "Pretty Print [report] ... "
    smallExport <- withTempFile "ppr.c" $ \hnd ->
      liftIO $ hPutStrLn hnd $ show (prettyUsingInclude ast)
    dbgMsg $ "to " ++ smallExport ++ "\n"

    lc <- liftIO $ lineCount fullExport
    return ((fullExport,smallExport), PerfMeasure (fromIntegral lc,t))

-- ===============
-- = Equiv Tests =
-- ===============
equivTestTemplate :: Test
equivTestTemplate = Test
  {
    testName = "equivalence check",
    testDescr = "check if two ASTs are equivalent",
    preferredScale = Unit,
    inputUnit = topLevelDeclarations
  }

runEquivTest :: CHeader -> CHeader -> TestMonad (Either (String, Maybe FilePath) PerfMeasure)
runEquivTest (CHeader decls1 _) (CHeader decls2 _) = do
  dbgMsg $ "Check AST equivalence\n"
  
  -- get generic asts
  (result,t) <- time $ do
    let ast1 = map toGenericAST decls1
    let ast2 = map toGenericAST decls2
    if (length ast1 /= length ast2)
      then 
        return $ Left ("Length mismatch: " ++ show (length ast1) ++ " vs. " ++ show (length ast2), Nothing)
      else 
        case find (\(_, (d1,d2)) -> d1 /= d2) (zip [0..] (zip ast1 ast2)) of
          Just (ix, (decl1,decl2)) -> do
            declf1 <- withTempFile ".1.ast"    $ \hnd -> liftIO $ hPutStrLn hnd (show $ pretty decl1)
            declf2 <- withTempFile ".2.ast"    $ \hnd -> liftIO $ hPutStrLn hnd (show $ pretty decl2)
            modify $ (addTmpFile declf1 . addTmpFile declf2)
            diff   <- withTempFile ".ast_diff" $ \_hnd -> return ()
            decl1Src <- liftIO $ getDeclSrc decls1 ix
            decl2Src <- liftIO $ getDeclSrc decls2 ix
            liftIO $ do
              appendFile diff ("Original declaration: \n" ++ decl1Src ++ "\n")
              appendFile diff ("Pretty printed declaration: \n" ++ decl2Src ++ "\n")
              system $ "diff -u '" ++ declf1 ++ "' '" ++ declf2 ++ "' >> '" ++ diff ++ "'" -- TODO: escape ' in filenames
            return $ Left ("Declarations do not match: ", Just diff)
          Nothing -> return $ Right (length ast1)
  return $ either Left (\decls -> Right $ PerfMeasure (fromIntegral decls, t)) result

getDeclSrc :: [CExtDecl] -> Int -> IO String
getDeclSrc decls ix = case drop ix decls of
  [] -> error "getDeclSrc : Bad ix"
  [decl] -> readFilePos (posOf decl) Nothing
  (decl:(declNext:_)) | fileOf decl /= fileOf declNext -> readFilePos (posOf decl) Nothing
                       | otherwise -> readFilePos (posOf decl) (Just (posRow $ posOf declNext))
  where
    fileOf = posFile . posOf
    readFilePos pos mLineNext = do
      let lnStart = posRow pos - 1
      lns <- liftM (drop lnStart . lines) $ readFile (posFile pos)
      (return.unlines) $
        case mLineNext of
          Nothing -> lns
          (Just lineNext) -> take (lineNext - lnStart - 1) lns
          
-- ===========
-- = Helpers =
-- ===========

--  make sure parse is evaluated
-- Rational: If we no wheter the parse result is an error or ok, we already have performed the parse
parseEval :: String -> Position -> TestMonad (Either ([String],Position) CHeader)
parseEval input initialPos = 
  case parseC input initialPos of 
    Left  err -> return $ Left err
    Right ok ->  return $ Right ok

eitherStatus :: Either a b -> String
eitherStatus = either (const "ERROR") (const "ok")

getContextInfo :: Position -> IO String
getContextInfo pos = do
  cnt <- readFile (posFile pos)
  return $ 
    case splitAt (posRow pos - 1) (lines cnt) of
      ([],[]) -> "/* No Input */"
      ([],ctxLine : post) -> showContext [] ctxLine (take 1 post)
      (pre,[]) -> showContext [last pre] "/* End Of File */" []
      (pre,ctxLine : post) -> showContext [last pre] ctxLine (take 1 post)
  where
    showContext preCtx ctx postCtx = unlines $ preCtx ++ [ctx, replicate (posColumn pos - 1) ' ' ++ "^^^"] ++ postCtx
    
locsOf :: String -> Integer
locsOf = fromIntegral . length . lines
                