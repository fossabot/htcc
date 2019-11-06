{-# LANGUAGE OverloadedStrings, TupleSections, LambdaCase, BangPatterns, ScopedTypeVariables #-}
{-|
Module      : Htcc.Parser.Core
Description : The C languge parser and AST constructor
Copyright   : (c) roki, 2019
License     : MIT
Maintainer  : falgon53@yahoo.co.jp
Stability   : experimental
Portability : POSIX

The C languge parser and AST constructor
-}
module Htcc.Parser.Core (
    -- * Recursive descent implementation functions
    program,
    globalDef,
    stmt,
    inners,
    logicalOr,
    logicalAnd,
    bitwiseOr,
    bitwiseXor,
    bitwiseAnd,
    shift,
    add,
    term,
    cast,
    unary,
    factor,
    relational,
    equality,
    conditional,
    assign,
    expr,
    -- * Parser
    parse,
    -- * Types and synonyms
    ASTSuccess,
    ASTConstruction,
    ASTResult,
    -- * Utilities
    stackSize,
    takePreType,
    takeType
) where

import Prelude hiding (toInteger)
import Data.Bits hiding (shift)
import Data.Bool (bool)
import qualified Data.ByteString as B
import Data.Tuple.Extra (first, second, uncurry3, snd3, dupe)
import Data.List (find, foldl')
import Data.List.Split (linesBy)
import Data.Either (isLeft, lefts, rights)
import Data.Maybe (isJust, fromJust, fromMaybe)
import Data.STRef (newSTRef, readSTRef, writeSTRef)
import qualified Data.Set as S
import qualified Data.Sequence as SQ
import qualified Data.Map.Strict as M
import qualified Data.Text as T
import Control.Monad (forM, when)
import Control.Monad.ST (runST)
import Control.Monad.Loops (unfoldrM)
import Numeric.Natural

import Htcc.Utils (
    first3, 
    second3,
    third3,
    tshow, 
    toNatural,
    toInteger,
    mapEither, 
    spanLen,
    dropFst3,
    dropFst4,
    dropSnd3, 
    dropThd3, 
    dropThd4,
    maybe')
import qualified Htcc.Tokenizer as HT
import qualified Htcc.CRules.Types as CT
import qualified Htcc.Parser.AST.Scope.Var as PV
import qualified Htcc.Parser.AST.Scope.Enumerator as SE
import Htcc.Parser.AST
import qualified Htcc.Parser.AST.Scope.Struct as PST
import qualified Htcc.Parser.AST.Scope.Typedef as PSD
import qualified Htcc.Parser.AST.Scope.Function as PSF
import Htcc.Parser.AST.Scope (Scoped (..), LookupVarResult (..))
import Htcc.Parser.AST.Scope.Utils (internalCE)
import Htcc.Parser.AST.Scope.ManagedScope (ASTError)
import Htcc.Parser.ConstructionData
import Htcc.Parser.Utils

takeStructFields :: (Integral i, Show i, Read i, Bits i) => [HT.TokenLC i] -> ConstructionData i -> Either (ASTError i) (M.Map T.Text (CT.StructMember i), ConstructionData i)
takeStructFields tk sc = takeStructFields' tk sc 0
    where
        takeStructFields' [] scp' _ = Right (M.empty, scp')
        takeStructFields' fs scp' !n = (>>=) (takeType fs scp') $ \case
            (ty@(CT.SCAuto _), Just (_, HT.TKIdent ident), (_, HT.TKReserved ";"):ds, scp'') -> let ofs = toNatural $ CT.alignas (toInteger n) $ toInteger $ CT.alignof ty in 
                first (M.insert ident (CT.StructMember (CT.fromsc ty) ofs)) <$> takeStructFields' ds scp'' (ofs + fromIntegral (CT.sizeof ty))
            (_, Just _, _, _) -> Left ("invalid storage-class specifier", head fs)
            _ -> Left ("expected member name or ';' after declaration specifiers", if null fs then HT.emptyToken else head fs)

takeEnumFiels :: (Integral i, Show i, Read i, Bits i) => CT.StorageClass i -> [HT.TokenLC i] -> ConstructionData i -> Either (ASTError i) (M.Map T.Text i, ConstructionData i)
takeEnumFiels = takeEnumFiels' 0
    where
        takeEnumFiels' !n ty [cur@(_, HT.TKIdent ident)] scp = (M.singleton ident n,) <$> addEnumerator ty cur n scp
        takeEnumFiels' !n ty (cur@(_, HT.TKIdent ident):(_, HT.TKReserved ","):xs) scp = (>>=) (takeEnumFiels' (succ n) ty xs scp) $ \(m, scp') -> 
            (M.insert ident n m,) <$> addEnumerator ty cur n scp'
        takeEnumFiels' _ ty (cur@(_, HT.TKIdent ident):(_, HT.TKReserved "="):xs) scp = case constantExp xs of
            Left (Just err) -> Left err
            Left Nothing -> Left ("The enumerator value for '" <> tshow (snd cur) <> "' is not an integer constant", cur)
            Right ((_, HT.TKReserved ","):ds, val) -> (>>=) (takeEnumFiels' (succ val) ty ds scp) $ \(m, scp') ->
                (M.insert ident val m,) <$> addEnumerator ty cur val scp'
            Right (ds, val) -> (>>=) (takeEnumFiels' (succ val) ty ds scp) $ \(m, scp') ->
                (M.insert ident val m,) <$> addEnumerator ty cur val scp'
        takeEnumFiels' _ _ ds _ = let lst = if null ds then HT.emptyToken else last ds in
            Left ("expected enum identifier_opt { enumerator-list } or enum identifier_opt { enumerator-list , }", lst)

{-# INLINE takeCtorPtr #-}
takeCtorPtr :: Integral i => [HT.TokenLC i] -> (CT.StorageClass i -> CT.StorageClass i, [HT.TokenLC i])
takeCtorPtr = first (CT.ctorPtr . toNatural) . dropSnd3 . spanLen ((==HT.TKReserved "*") . snd)

-- It is obtained by parsing the front part of the type from the token string. 
-- e.g. @int (*)[4]@ applied to this function yields @int@
takePreType :: (Integral i, Show i, Read i, Bits i) => [HT.TokenLC i] -> ConstructionData i -> Either (ASTError i) (CT.StorageClass i, [HT.TokenLC i], ConstructionData i)
takePreType ((_, HT.TKType ty1):y@(iy, HT.TKType ty2):xs) scp = maybe' (Left (T.singleton '\'' <> tshow ty1 <> " " <> tshow ty2 <> "' is invalid.", y)) (CT.qualify ty1 ty2) $ \ty -> -- for a complex type
    takePreType ((iy, HT.TKType ty):xs) scp
takePreType ((_, HT.TKType ty):xs) scp = Right (CT.SCAuto $ CT.fromsc $ CT.implicitInt ty, xs, scp) -- for fundamental type
takePreType ((_, HT.TKStruct):cur@(_, HT.TKReserved "{"):xs) scp = maybe' (Left (internalCE, cur)) (takeBrace "{" "}" (cur:xs)) $ -- for @struct@
    either (Left . ("expected '}' token to match this '{'",)) $ \(field, ds) -> uncurry (,ds,) . first (CT.SCAuto . CT.CTStruct) <$> takeStructFields (tail $ init field) scp
takePreType ((_, HT.TKStruct):cur1@(_, HT.TKIdent _):cur2@(_, HT.TKReserved "{"):xs) scp = maybe' (Left (internalCE, cur1)) (takeBrace "{" "}" (cur2:xs)) $ -- for @struct@ with tag
    either (Left . ("expected '}' token to match this '{'",)) $ \(field, ds) -> (>>=) (takeStructFields (tail $ init field) scp) $ \(mem, scp') -> let ty = CT.SCAuto $ CT.CTStruct mem in
        addTag ty cur1 scp' >>= Right . (ty, ds,) 
takePreType ((_, HT.TKStruct):cur1@(_, HT.TKIdent ident):xs) scp = maybe' (Left ("storage size of '" <> ident <> "' isn't known", cur1)) (lookupTag ident scp) $ Right . (, xs, scp) . PST.sttype -- declaration for @struct@
takePreType (cur@(_, HT.TKIdent ident):xs) scp = maybe' (Left (T.singleton '\'' <> tshow (snd cur) <> "' is not a type or also a typedef identifier", cur)) (lookupTypedef ident scp) $ Right . (, xs, scp) . PSD.tdtype -- declaration for @typedef@
takePreType ((_, HT.TKEnum):cur@(_, HT.TKReserved "{"):xs) scp = maybe' (Left (internalCE, cur)) (takeBrace "{" "}" (cur:xs)) $ -- for @enum@
    either (Left . ("expected '}' token to match this '{'",)) $ \(field, ds) -> uncurry (,ds,) . first (CT.SCAuto . CT.CTEnum CT.CTInt) <$> takeEnumFiels (CT.SCAuto CT.CTInt) (tail $ init field) scp
takePreType ((_, HT.TKEnum):cur1@(_, HT.TKIdent _):cur2@(_, HT.TKReserved "{"):xs) scp = maybe' (Left (internalCE, cur1)) (takeBrace "{" "}" (cur2:xs)) $ -- for @enum@ with tag
    either (Left . ("expected '}' token to match this '{'",)) $ \(field, ds) -> (>>=) (takeEnumFiels (CT.SCAuto CT.CTInt) (tail $ init field) scp) $ \(mem, scp') -> let ty = CT.SCAuto $ CT.CTEnum CT.CTInt mem in
        addTag ty cur1 scp' >>= Right . (ty, ds,)
takePreType ((_, HT.TKEnum):cur1@(_, HT.TKIdent ident):xs) scp = maybe' (Left ("storage size of '" <> ident <> "' isn't known", cur1)) (lookupTag ident scp) $ Right . (, xs, scp) . PST.sttype -- declaration for @enum@
takePreType ((_, HT.TKReserved _):cur@(_, HT.TKReserved _):_) _ = Left ("cannot combine with previous '" <> tshow (snd cur) <> "' declaration specifier", cur)
takePreType ((_, HT.TKReserved "static"):xs) scp = first3 (CT.SCStatic . CT.fromsc) <$> takePreType xs scp
takePreType ((_, HT.TKReserved "register"):xs) scp = first3 (CT.SCRegister . CT.fromsc) <$> takePreType xs scp
takePreType ((_, HT.TKReserved "auto"):xs) scp = takePreType xs scp
takePreType (x:_) _ = Left ("ISO C forbids declaration with no type", x)
takePreType _ _ = Left ("ISO C forbids declaration with no type", HT.emptyToken)

{-# INLINE declaration #-}
declaration :: (Integral i, Bits i, Show i, Read i) => CT.StorageClass i -> [HT.TokenLC i] -> Either (ASTError i) (CT.StorageClass i, Maybe (HT.TokenLC i), [HT.TokenLC i])
declaration ty xs = case takeCtorPtr xs of 
    (fn, xs'@((_, HT.TKReserved "("):_)) -> declaration' id (fn ty) xs' >>= uncurry3 (validDecl HT.emptyToken) . dropFst4
    (fn, ident@(_, HT.TKIdent _):ds') -> case arrayDeclSuffix (fn ty) ds' of
        Nothing -> validDecl ident (fn ty) (Just ident) ds'
        Just rs -> rs >>= uncurry (flip (validDecl ident) (Just ident))
    (fn, es) -> validDecl HT.emptyToken (fn ty) Nothing es
    where
        validDecl errtk t ident ds
            | CT.fromsc t == CT.CTVoid = Left ("variable or field '" <> tshow (snd errtk) <> "' declared void", errtk) 
            | otherwise = Right (t, ident, ds)
        declaration' fn ty' xs' = case takeCtorPtr xs' of
            (ptrf, cur@(_, HT.TKReserved "("):ds') -> (>>=) (declaration' (fn . ptrf) ty' ds') $ \case
                (ptrf', ty'', ident, (_, HT.TKReserved ")"):ds'') -> case arrayDeclSuffix ty'' ds'' of
                    Nothing -> Right (id, ptrf' ty', ident, ds'')
                    Just rs -> uncurry (id,,ident,) . first ptrf' <$> rs
                _ -> Left ("expected ')' token for this '('", cur)
            (ptrf, ident@(_, HT.TKIdent _):ds') -> case arrayDeclSuffix ty' ds' of
                Nothing -> Right (ptrf, ty', Just ident, ds')
                Just rs -> uncurry (ptrf,,Just ident,) <$> rs 
            _ -> Left ("expected some identifier", HT.emptyToken)

-- `takeType` returns a pair of type (including pointer and array type) and the remaining tokens wrapped in 
-- `Just` only if the token starts with `HT.TKType`, `HT.TKStruct` or identifier that is declarated by @typedef@.
-- Otherwise `Nothing` is returned.
takeType :: (Integral i, Show i, Read i, Bits i) => [HT.TokenLC i] -> ConstructionData i -> Either (ASTError i) (CT.StorageClass i, Maybe (HT.TokenLC i), [HT.TokenLC i], ConstructionData i)
takeType tk scp = takePreType tk scp >>= (\(x, y, z) -> uncurry3 (,,, z) <$> declaration x y)

-- `absDeclaration` parses abstract type declarations
absDeclaration :: (Integral i, Bits i, Show i, Read i) => CT.StorageClass i -> [HT.TokenLC i] -> Either (ASTError i) (CT.StorageClass i, [HT.TokenLC i])
absDeclaration ty xs = case takeCtorPtr xs of
    (fn, xs'@((_, HT.TKReserved "("):_)) -> dropFst3 <$> absDeclarator' id (fn ty) xs'
    (fn, ds) -> fromMaybe (Right (fn ty, ds)) $ arrayDeclSuffix (fn ty) ds
    where
        absDeclarator' fn ty' xs' = case takeCtorPtr xs' of
            (ptrf, cur@(_, HT.TKReserved "("):ds') -> (>>=) (absDeclarator' (fn . ptrf) ty' ds') $ \case
                (ptrf', ty'', (_, HT.TKReserved ")"):ds'') -> maybe (Right (id, ptrf' ty'', ds'')) (fmap (uncurry (id,,) . first ptrf')) $ arrayDeclSuffix ty'' ds''
                _ -> Left ("expected ')' token for this '('", cur)
            (p, ds) -> Right (p, ty', ds)

-- `takeTypeName` is used to parse type names used for sizeof etc. Version without `takeType`s identifier.
takeTypeName :: (Integral i, Show i, Read i, Bits i) => [HT.TokenLC i] -> ConstructionData i -> Either (ASTError i) (CT.StorageClass i, [HT.TokenLC i])
takeTypeName tk scp = (>>=) (takePreType tk scp) $ \(x, y, _) -> if CT.isSCStatic x then Left ("storage-class specifier is not allowed", head tk) else absDeclaration x y

-- For a number \(n\in\mathbb{R}\), let \(k\) be the number of consecutive occurrences of
-- @HT.TKReserved "[", n, HT.TKReserved "]"@ from the beginning of the token sequence.
-- `arrayDeclSuffix` constructs an array type of the given type @t@ based on 
-- the token sequence if \(k\leq 1\), wraps it in `Right` and `Just` and returns it with the rest of the token sequence.
-- If the token @HT.TKReserved "["@ exists at the beginning of the token sequence, 
-- but the subsequent token sequence is invalid as an array declaration in C programming language,
-- an error mesage and the token at the error location are returned wrapped in
-- `Left` and `Just`. When \(k=0\), `Nothing` is returned.
arrayDeclSuffix :: forall i. (Integral i, Bits i, Show i, Read i) => CT.StorageClass i -> [HT.TokenLC i] -> Maybe (Either (ASTError i) (CT.StorageClass i, [HT.TokenLC i]))
arrayDeclSuffix t (cur@(_, HT.TKReserved "["):xs) = case constantExp xs of
    Left (Just err) -> Just $ Left err
    Left Nothing -> Just $ Left $ if null xs then ("The expression is not constant-expression", cur) else
        ("The expression '" <> tshow (snd $ head xs) <> "' is not constant-expression", head xs)
    Right ((_, HT.TKReserved "]"):ds, val) -> maybe' (Just $ Right (CT.picksc t $ CT.CTArray (toNatural val) (CT.fromsc t), ds)) (arrayDeclSuffix t ds) $
        Just . fmap (first $ fromJust . CT.concatCTArray (CT.picksc t $ CT.CTArray (toNatural val) (CT.fromsc t)))
    _ -> Just $ Left ("expected storage size after '[' token", cur)
arrayDeclSuffix _ _ = Nothing
        
{-# INLINE isTypeName #-}
isTypeName :: HT.TokenLC i -> ConstructionData i -> Bool
isTypeName (_, HT.TKType _) _ = True
isTypeName (_, HT.TKStruct) _ = True
isTypeName (_, HT.TKEnum) _ = True
isTypeName (_, HT.TKReserved "static") _ = True
isTypeName (_, HT.TKReserved "auto") _ = True
isTypeName (_, HT.TKReserved "register") _ = True
isTypeName (_, HT.TKIdent ident) scp = isJust $ lookupTypedef ident scp
isTypeName _ _ = False

{-# INLINE varDecl #-}
varDecl :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
varDecl tk atn scp = takeType tk scp >>= varDecl'
    where
        varDecl' (_, Nothing, (_, HT.TKReserved ";"):ds, scp') = Right (ds, ATEmpty, scp')
        varDecl' (t, Just ident, (_, HT.TKReserved ";"):ds, scp') = (>>=) (addLVar t ident scp') $ \(lat, scp'') -> Right (ds, ATNode (ATNull lat) (CT.SCUndef CT.CTUndef) ATEmpty ATEmpty, scp'')
        varDecl' (t, Just ident, (_, HT.TKReserved "="):ds, scp') = (>>=) (addLVar t ident scp') $ \(lat, scp'') -> (>>=) (expr ds atn scp'') $ \(ert, erat, ervar) -> case ert of
            (_, HT.TKReserved ";"):ds' -> Right (ds', ATNode ATExprStmt (CT.SCUndef CT.CTUndef) (ATNode ATAssign (atype lat) lat erat) ATEmpty, ervar)
            _ -> Left ("expected ';' token. The subject iteration statement start here:", head tk)
        varDecl' (_, _, ds, _) = Left $ if null ds then ("expected unqualified-id", head tk) else ("expected unqualified-id before '" <> tshow (snd (head ds)) <> T.singleton '\'', head ds)

-- The `Just` represents an error during construction of the syntax tree, and the `Nothing` represents no valid constant expression.
type ConstantResult i = Maybe (ASTError i)

-- `constantExp` evaluates to a constant expression from token list.
constantExp :: forall i. (Bits i, Integral i, Show i, Read i) => [HT.TokenLC i] -> Either (ConstantResult i) ([HT.TokenLC i], i)
constantExp tk = flip (either (Left . Just)) (conditional tk ATEmpty initConstructionData) $ \(ds, at, _) -> 
    maybe (Left Nothing) (Right . (ds, )) $ evalConstantExp at
    where
        evalConstantExp :: ATree i -> Maybe i
        evalConstantExp (ATNode k _ lhs rhs) = let fromBool = fromIntegral . fromEnum :: Bool -> i in case k of
            ATAdd -> binop (+)
            ATSub -> binop (-) 
            ATMul -> binop (*)
            ATDiv -> binop div
            ATAnd -> binop (.&.) 
            ATXor -> binop xor
            ATOr -> binop (.|.) 
            ATShl -> binop (flip (.) fromIntegral . shiftL)
            ATShr -> binop (flip (.) fromIntegral . shiftR)
            ATEQ -> binop ((.) fromBool . (==)) 
            ATNEQ -> binop ((.) fromBool . (/=)) 
            ATLT -> binop ((.) fromBool . (<)) 
            ATGT -> binop ((.) fromBool . (>)) 
            ATLEQ -> binop ((.) fromBool . (<=)) 
            ATGEQ -> binop ((.) fromBool . (>=)) 
            ATConditional cn th el -> evalConstantExp cn >>= bool (evalConstantExp el) (evalConstantExp th) . castBool
            ATComma -> evalConstantExp rhs
            ATNot ->  fromIntegral . fromEnum . not . castBool <$> evalConstantExp lhs
            ATBitNot -> complement <$> evalConstantExp lhs
            ATLAnd -> binop ((.) fromBool . flip (.) castBool . (&&) . castBool)
            ATLOr -> binop ((.) fromBool . flip (.) castBool . (||) . castBool)
            ATNum v -> Just v
            _ -> Nothing
            where
                binop f = (>>=) (evalConstantExp lhs) $ \lhs' -> fromIntegral . f lhs' <$> evalConstantExp rhs
                castBool x | x == 0 = False | otherwise = True
        evalConstantExp ATEmpty = Nothing

-- | The type to be used when the AST construction is successful
type ASTSuccess i = ([HT.TokenLC i], ATree i, ConstructionData i)

-- | Types used during AST construction
type ASTConstruction i = Either (ASTError i) (ASTSuccess i)

-- | A type that represents the result after AST construction. Quadraple of warning list, constructed abstract syntax tree list, global variable map, literal list.
type ASTResult i = Either (ASTError i) (SQ.Seq (ASTError i), [ATree i], M.Map T.Text (PV.GVar i), [PV.Literal i])

-- | Perform type definition from token string starting from @typedef@ token
defTypedef :: (Integral i, Show i, Read i, Bits i) => [(HT.TokenLCNums i, HT.Token i)] -> ConstructionData i -> Either (ASTError i) ([HT.TokenLC i], ATree a, ConstructionData i)
defTypedef ((_, HT.TKTypedef):cur@(_, HT.TKReserved _):_) _ = Left ("storage-class specifier is not allowed in this context", cur)
defTypedef (cur@(_, HT.TKTypedef):xs) !scp = case takeType xs scp of
    Left er -> Left er
    Right (ty, Just ident, ds, scp') -> case ds of
        (_, HT.TKReserved ";"):ds' -> (ds', ATEmpty,) <$> addTypedef ty ident scp'
        _ -> Left ("expected ';' token after '" <> tshow (snd ident) <> "'", ident)
    Right (_, Nothing, ds, scp') -> case ds of
        (_, HT.TKReserved ";"):ds' -> Right (ds', ATEmpty, pushWarn "useless type name in empty declaration" cur scp')
        _ -> Left $ if not (null ds) then ("expected ';' token after '" <> tshow (snd $ head ds) <> "'", head ds) else ("expected ';' token", HT.emptyToken)
defTypedef _ _ = Left (internalCE, HT.emptyToken)

-- | `program` indicates \(\eqref{eq:eigth}\) among the comments of `inners`.
program :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ConstructionData i -> Either (ASTError i) ([ATree i], ConstructionData i)
program [] !scp = Right ([], scp)
program xs !scp = either Left (\(ys, atn, !scp') -> first (atn:) <$> program ys scp') $ globalDef xs ATEmpty scp

-- | `globalDef` parses global definitions (include functions and global variables)
globalDef :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
globalDef (cur@(_, HT.TKReserved "register"):_) _ _ = Left ("illegal storage class on file-scoped identifier", cur)
globalDef (cur@(_, HT.TKReserved "auto"):_) _ _ = Left ("illegal storage class on file-scoped identifier", cur)
globalDef xs@((_, HT.TKTypedef):_) _ sc = defTypedef xs sc -- for global @typedef@
globalDef tks at !va = (>>=) (takeType tks va) $ \case
    (_, Nothing, (_, HT.TKReserved ";"):ds', scp) -> Right (ds', ATEmpty, scp) -- e.g., @int;@ is legal in C11 (See N1570/section 6.7 Declarations)
    (funcType, Just (cur@(_, HT.TKIdent fname)), tk@((_, HT.TKReserved "("):_), !sc) -> let scp = resetLocal sc in -- for a function declaration or definition
        maybe' (Left (internalCE, cur)) (takeBrace "(" ")" $ tail (cur:tk)) $
            either (Left . ("invalid function declaration/definition",)) $ \(fndec, st) -> case st of
                ((_, HT.TKReserved ";"):ds'') -> addFunction False funcType cur scp >>= globalDef ds'' at -- for a function declaration
                ((_, HT.TKReserved "{"):_) -> (>>=) (addFunction True funcType cur scp) $ \scp' -> checkErr fndec scp' $ \args -> runST $ do -- for a function definition
                    eri <- newSTRef Nothing
                    v <- newSTRef scp'
                    mk <- flip unfoldrM args $ \args' -> if null args' then return Nothing else let arg = head args' in do
                        m <- uncurry addLVar (second fromJust $ dropThd3 $ dropThd4 arg) <$> readSTRef v
                        flip (either ((<$) Nothing . writeSTRef eri . Just)) m $ \(vat, scp'') -> Just (vat, tail args') <$ writeSTRef v scp''
                    (>>=) (readSTRef eri) $ flip maybe (return . Left) $
                        fmap (second3 (flip (ATNode (ATDefFunc fname $ if null mk then Nothing else Just mk) funcType) ATEmpty)) . stmt st at <$> readSTRef v
                _ -> stmt tk at scp
    (ty, Just (cur@(_, HT.TKIdent _)), xs, !scp) -> case xs of -- for global variables -- TODO: support initialize by global variables
        (_, HT.TKReserved ";"):ds -> flip fmap (addGVar ty cur scp) $ \(_, scp') -> (ds, ATEmpty, scp')
        _ -> Left ("expected ';' token after '" <> tshow (snd cur) <> "' token", cur)
    _ -> Left ("invalid definition of global identifier", if null tks then HT.emptyToken else head tks)
    where
        checkErr ar !scp' f = let ar' = init $ tail ar in if not (null ar') && snd (head ar') == HT.TKReserved "," then Left ("unexpected ',' token", head ar') else
            let args = linesBy ((==HT.TKReserved ",") . snd) ar' in mapEither (`takeType` scp') args >>= f


-- | `stmt` indicates \(\eqref{eq:nineth}\) among the comments of `inners`.
stmt :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
stmt (cur@(_, HT.TKReturn):xs) atn !scp = (>>=) (expr xs atn scp) $ \(ert, erat, erscp) -> case ert of -- for @return@
    (_, HT.TKReserved ";"):ys -> Right (ys, ATNode ATReturn (CT.SCUndef CT.CTUndef) erat ATEmpty, erscp)
    ert' -> Left $ expectedMessage ";" cur ert'
stmt (cur@(_, HT.TKIf):(_, HT.TKReserved "("):xs) atn !scp = (>>=) (expr xs atn scp) $ \(ert, erat, erscp) -> case ert of -- for @if@
    (_, HT.TKReserved ")"):ys -> (>>=) (stmt ys erat erscp) $ \x -> case second3 (ATNode ATIf (CT.SCUndef CT.CTUndef) erat) x of
        ((_, HT.TKElse):zs, eerat, eerscp) -> second3 (ATNode ATElse (CT.SCUndef CT.CTUndef) eerat) <$> stmt zs eerat eerscp -- for @else@
        zs -> Right zs
    ert' -> Left $ expectedMessage ")" cur ert'
stmt (cur@(_, HT.TKWhile):(_, HT.TKReserved "("):xs) atn !scp = (>>=) (expr xs atn scp) $ \(ert, erat, erscp) -> case ert of -- for @while@
    (_, HT.TKReserved ")"):ys -> second3 (ATNode ATWhile (CT.SCUndef CT.CTUndef) erat) <$> stmt ys erat erscp
    ert' -> Left $ expectedMessage ")" cur ert'
stmt xxs@(cur@(_, HT.TKFor):(_, HT.TKReserved "("):_) _ !scp = maybe' (Left (internalCE, cur)) (takeBrace "(" ")" (tail xxs)) $ -- for @for@
    either (Left . ("expected ')' token. The subject iteration statement starts here:",)) $ \(forSt, ds) -> (>>=) (initSect (tail (init forSt)) $ succNest scp) $ \(fxs, finit, fscp') ->
        (>>=) (condSect fxs fscp') $ \(fxs', fcond, fscp'') -> (>>=) (incrSect fxs' fscp'') $ \case
            ([], fincr, fscp''') -> 
                let fnd = filter (\x' -> case fromATKindFor x' of ATEmpty -> False; x'' -> not $ isEmptyExprStmt x'') [ATForInit finit, ATForCond fcond, ATForIncr fincr]
                    mkk = maybe (ATForCond (ATNode (ATNum 1) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty) : fnd) (const fnd) $ find isATForCond fnd in case ds of
                        ((_, HT.TKReserved ";"):ys) -> Right (ys, ATNode (ATFor mkk) (CT.SCUndef CT.CTUndef) ATEmpty ATEmpty, fallBack scp fscp''')
                        _ -> third3 (fallBack scp) . second3 (flip (flip (flip ATNode $ CT.SCUndef CT.CTUndef) ATEmpty) ATEmpty . ATFor . (mkk ++) . (:[]) . ATForStmt) <$> stmt ds ATEmpty fscp'''
            _ -> Left ("unexpected end of for statement", cur)
    where
        initSect [] _ = Left ("the iteration statement for must be `for (expression_opt; expression_opt; expression_opt) statement`. See section 6.8.5.", cur)
        initSect ((_, HT.TKReserved ";"):ds) fsc = Right (ds, ATEmpty, fsc)
        initSect forSect fsc
            | isTypeName (head forSect) fsc = varDecl forSect ATEmpty fsc
            | otherwise = (>>=) (expr forSect ATEmpty fsc) $ \(x, y, z) -> case x of
                (_, HT.TKReserved ";"):ds -> Right (ds, ATNode ATExprStmt (CT.SCUndef CT.CTUndef) y ATEmpty, z)
                _ -> if null x then Left ("expected ';' token", HT.emptyToken) else Left ("expected ';' token after '" <> tshow (snd $ head x) <> "'", head x)
        condSect [] _ = Left ("the iteration statement for must be `for (expression_opt; expression_opt; expression_opt) statement`. See section 6.8.5.", cur)
        condSect ((_, HT.TKReserved ";"):ds) fsc = Right (ds, ATEmpty, fsc)
        condSect forSect fsc = (>>=) (expr forSect ATEmpty fsc) $ \case
            ((_, HT.TKReserved ";"):ds, y, z) -> Right (ds, y, z)
            (x, _, _) -> if null x then Left ("expected ';' token", HT.emptyToken) else Left ("expected ';' token after '" <> tshow (snd $ head x) <> "'", head x)
        incrSect [] fsc = Right ([], ATEmpty, fsc)
        incrSect forSect fsc = second3 (flip (ATNode ATExprStmt $ CT.SCUndef CT.CTUndef) ATEmpty) <$> expr forSect ATEmpty fsc
stmt xxs@(cur@(_, HT.TKReserved "{"):_) _ !scp = maybe' (Left (internalCE, cur)) (takeBrace "{" "}" xxs) $ -- for compound statement
    either (Left . ("the compound statement is not closed",)) $ \(sctk, ds) -> runST $ do
        eri <- newSTRef Nothing
        v <- newSTRef $ succNest scp
        mk <- flip unfoldrM (init $ tail sctk) $ \ert -> if null ert then return Nothing else do
            erscp <- readSTRef v
            either (\err -> Nothing <$ writeSTRef eri (Just err)) (\(ert', erat', erscp') -> Just (erat', ert') <$ writeSTRef v erscp') $ stmt ert ATEmpty erscp
        (>>=) (readSTRef eri) $ flip maybe (return . Left) $ Right . (ds, ATNode (ATBlock mk) (CT.SCUndef CT.CTUndef) ATEmpty ATEmpty,) . fallBack scp <$> readSTRef v
stmt ((_, HT.TKReserved ";"):xs) atn !scp = Right (xs, atn, scp) -- for only @;@
stmt xs@((_, HT.TKTypedef):_) _ scp = defTypedef xs scp -- for local @typedef@
stmt tk atn !scp
    | not (null tk) && isTypeName (head tk) scp = varDecl tk atn scp -- for a local variable declaration
    | otherwise = (>>=) (expr tk atn scp) $ \(ert, erat, erscp) -> case ert of -- for stmt;
        (_, HT.TKReserved ";"):ys -> Right (ys, ATNode ATExprStmt (CT.SCUndef CT.CTUndef) erat ATEmpty, erscp)
        ert' -> Left $ expectedMessage ";" (if null tk then HT.emptyToken else last tk) ert'

{-# INLINE expr #-}
-- | \({\rm expr} = {\rm assign}\left("," {\rm assign}\right)\ast\)
expr :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
expr tk at cd = assign tk at cd >>= uncurry3 f
    where
        f ((_, HT.TKReserved ","):xs) at' cd' = assign xs at' cd' >>= uncurry3 f . second3 (\x -> ATNode ATComma (atype x) (ATNode ATExprStmt (CT.SCUndef CT.CTUndef) at' ATEmpty) x)
        f tk' at' cd' =  Right (tk', at', cd')

-- | `assign` indicates \(\eqref{eq:seventh}\) among the comments of `inners`.
assign :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
assign xs atn scp = (>>=) (conditional xs atn scp) $ \(ert, erat, erscp) -> case ert of
    (_, HT.TKReserved "="):ys -> nextNode ATAssign ys  erat erscp
    (_, HT.TKReserved "*="):ys -> nextNode ATMulAssign ys erat erscp
    (_, HT.TKReserved "/="):ys -> nextNode ATDivAssign ys erat erscp
    (_, HT.TKReserved "&="):ys -> nextNode ATAndAssign ys erat erscp
    (_, HT.TKReserved "|="):ys -> nextNode ATOrAssign ys erat erscp
    (_, HT.TKReserved "^="):ys -> nextNode ATXorAssign ys erat erscp
    (_, HT.TKReserved "<<="):ys -> nextNode ATShlAssign ys erat erscp
    (_, HT.TKReserved ">>="):ys -> nextNode ATShrAssign ys erat erscp
    (_, HT.TKReserved "+="):ys -> nextNode (maybe ATAddAssign (const ATAddPtrAssign) $ CT.deref (atype erat)) ys erat erscp
    (_, HT.TKReserved "-="):ys -> nextNode (maybe ATSubAssign (const ATSubPtrAssign) $ CT.deref (atype erat)) ys erat erscp
    _ -> Right (ert, erat, erscp)
    where
        nextNode atk ys erat erscp = second3 (ATNode atk (atype erat) erat) <$> assign ys erat erscp

-- | `conditional` indicates \(\eqref{eq:seventeenth}\) among the comments of `inners`.
conditional :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
conditional xs atn scp = (>>=) (logicalOr xs atn scp) $ \(ert, cond, erscp) -> case ert of
    cur@(_, HT.TKReserved "?"):ds -> (>>=) (expr ds cond erscp) $ \(ert', thn, erscp') -> case ert' of
        (_, HT.TKReserved ":"):ds' -> second3 (flip (flip (flip ATNode (atype thn)) ATEmpty) ATEmpty . ATConditional cond thn) <$> conditional ds' thn erscp'
        ds' -> if null ds' then Left ("expected ':' token for this '?'", cur) else Left ("expected ':' before '" <> tshow (snd (head ds')) <> "' token", head ds')
    _ -> Right (ert, cond, erscp)

-- | `inners` is a general function for creating `equality`, `relational`, `add` and `term` in the following syntax (EBNF) of \({\rm LL}\left(k\right)\) where \(k\in\mathbb{N}\).
--
-- \[
-- \begin{eqnarray}
-- {\rm program} &=& {\rm stmt}^\ast\label{eq:eigth}\tag{1}\\
-- {\rm stmt} &=& \begin{array}{l}
-- {\rm expr}?\ {\rm ";"}\\ 
-- \mid\ {\rm "\{"\ stmt}^\ast\ {\rm "\}"}\\
-- \mid\ {\rm "return"}\ {\rm expr}\ ";"\\
-- \mid\ "{\rm if}"\ "("\ {\rm expr}\ ")"\ {\rm stmt}\ ("{\rm else}"\ {\rm stmt})?\\
-- \mid\ {\rm "while"\ "("\ expr\ ")"\ stmt}\\
-- \mid\ {\rm "for"\ "("\ expr?\ ";" expr?\ ";"\ expr?\ ")"\ stmt? ";"}
-- \end{array}\label{eq:nineth}\tag{2}\\
-- {\rm expr} &=& {\rm assign}\\
-- {\rm assign} &=& {\rm conditional} \left(\left("="\ \mid\ "+="\ \mid\ "-="\ \mid\ "*="\ \mid\ "/="\right)\ {\rm assign}\right)?\label{eq:seventh}\tag{3}\\
-- {\rm conditional} &=& {\rm logicalOr} \left("?"\ {\rm expr}\ ":"\ {\rm conditional}\right)?\label{eq:seventeenth}\tag{4}\\
-- {\rm logicalOr} &=& {\rm logicalAnd}\ \left("||"\ {\rm logicalAnd}\right)^\ast\label{eq:fifteenth}\tag{5}\\
-- {\rm logicalAnd} &=& {\rm bitwiseOr}\ \left("|"\ {\rm bitwiseOr}\right)^\ast\label{eq:sixteenth}\tag{6}\\
-- {\rm bitwiseOr} &=& {\rm bitwiseXor}\ \left("|"\ {\rm bitwiseXor}\right)^\ast\label{eq:tenth}\tag{7}\\
-- {\rm bitwiseXor} &=& {\rm bitwiseAnd}\ \left("\hat{}"\ {\rm bitwiseAnd}\right)^\ast\label{eq:eleventh}\tag{8}\\
-- {\rm bitwiseAnd} &=& {\rm equality}\ \left("\&"\ {\rm equality}\right)^\ast\label{eq:twelveth}\tag{9}\\
-- {\rm equality} &=& {\rm relational}\ \left("=="\ {\rm relational}\ \mid\ "!="\ {\rm relational}\right)^\ast\label{eq:fifth}\tag{10}\\
-- {\rm relational} &=& {\rm shift}\ \left("\lt"\ {\rm shift}\mid\ "\lt ="\ {\rm shift}\mid\ "\gt"\ {\rm shift}\mid\ "\gt ="\ {\rm shift}\right)^\ast\label{eq:sixth}\tag{11}\\
-- {\rm shift} &=& {\rm add}\ \left("\lt\lt"\ {\rm add}\mid\ "\gt\gt"\ {\rm add}\right)^\ast\label{eq:thirteenth}\tag{12}\\
-- {\rm add} &=& {\rm term}\ \left("+"\ {\rm term}\ \mid\ "-"\ {\rm term}\right)^\ast\label{eq:first}\tag{13} \\
-- {\rm term} &=& {\rm factor}\ \left("\ast"\ {\rm factor}\ \mid\ "/"\ {\rm factor}\right)^\ast\label{eq:second}\tag{14} \\
-- {\rm cast} &=& "(" {\rm type-name} ")"\ {\rm cast}\ \mid\ {\rm unary}\label{eq:fourteenth}\tag{15} \\
-- {\rm unary} &=& \left("+"\ \mid\ "-"\right)?\ {\rm cast}\mid\ \left("!"\ \mid\ "\sim"\ \mid\ "\&"\ \mid\ "\ast"\right)?\ {\rm unary}\label{eq:fourth}\tag{16} \\
-- {\rm factor} &=& {\rm num} \mid\ {\rm ident}\ \left({\rm "(" \left(expr\ \left(\left(","\ expr\right)^\ast\right)?\right)? ")"}\right)?\ \mid\ "(" {\rm expr} ")"\label{eq:third}\tag{17}
-- \end{eqnarray}
-- \]
inners :: ([HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i) -> [(T.Text, ATKind i)] -> [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
inners _ _ [] atn scp = Right ([], atn, scp)
inners f cs xs atn scp = either Left (uncurry3 (inners' f cs)) $ f xs atn scp
    where
        inners' _ _ [] at ars = Right ([], at, ars)
        inners' g ds ys at ars = maybe' (Right (ys, at, ars)) (find (\(c, _) -> case snd (head ys) of HT.TKReserved cc -> cc == c; _ -> False) ds) $ \(_, k) -> 
            either Left (uncurry3 id . first3 (inners' f cs) . second3 (ATNode k (CT.SCAuto CT.CTInt) at)) $ g (tail ys) at ars

-- | `logicalOr` indicates \(\eqref{eq:fifteenth}\) among the comments of `inners`.
logicalOr :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
logicalOr = inners logicalAnd [("||", ATLOr)]

-- | `logicalAnd` indicates \(\eqref{eq:sixteenth}\) among the comments of `inners`.
logicalAnd :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
logicalAnd = inners bitwiseOr [("&&", ATLAnd)]

-- | `bitwiseOr` indicates \(\eqref{eq:tenth}\) among the comments of `inners`.
bitwiseOr :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
bitwiseOr = inners bitwiseXor [("|", ATOr)]

-- | `bitwiseXor` indicates \(\eqref{eq:eleventh}\) amont the comments of `inners`.
bitwiseXor :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
bitwiseXor = inners bitwiseAnd [("^", ATXor)]

-- | `bitwiseAnd` indicates \(\eqref{eq:twelveth}\) among the comments of `inners`.
bitwiseAnd :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
bitwiseAnd = inners equality [("&", ATAnd)]

-- | `equality` indicates \(\eqref{eq:fifth}\) among the comments of `inners`.
-- This is equivalent to the following code:
--
--
-- > equality ::  [HT.TokenLC i] -> ATree i -> [LVar i] -> Either (ASTError i) ([HT.TokenLC i], ATree i)
-- > equality xs atn scp = (>>=) (relational xs atn scp) $ uncurry3 equality'
-- >     where
-- >         equality' ((_, HT.TKReserved "=="):ys) era ars = either Left (uncurry3 id . first3 equality' . second3 (ATNode ATEQ era)) $ relational ys era ars
-- >         equality' ((_, HT.TKReserved "!="):ys) era ars = either Left (uncurry3 id . first3 equality' . second3 (ATNode ATNEQ era)) $ relational ys era ars
-- >         equality' ert era ars = Right (ert, era, ars)
equality :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
equality = inners relational [("==", ATEQ), ("!=", ATNEQ)]

-- | `relational` indicates \(\eqref{eq:sixth}\) among the comments of `inners`.
relational :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
relational = inners shift [("<", ATLT), ("<=", ATLEQ), (">", ATGT), (">=", ATGEQ)]

-- | `shift` indicates \(\eqref{eq:thirteenth}\\) among the comments of `inners`.
shift :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
shift = inners add [("<<", ATShl), (">>", ATShr)]
        
{-# INLINE addKind #-}
addKind :: (Eq i, Ord i, Show i) => ATree i -> ATree i -> Maybe (ATree i)
addKind lhs rhs
    | all (CT.isFundamental . atype) [lhs, rhs] = Just $ ATNode ATAdd (CT.conversion (atype lhs) (atype rhs)) lhs rhs
    | isJust (CT.deref $ atype lhs) && CT.isFundamental (atype rhs) = Just $ ATNode ATAddPtr (atype lhs) lhs rhs
    | CT.isFundamental (atype lhs) && isJust (CT.deref $ atype rhs) = Just $ ATNode ATAddPtr (atype rhs) rhs lhs
    | otherwise = Nothing

{-# INLINE subKind #-}
subKind :: (Eq i, Ord i) => ATree i -> ATree i -> Maybe (ATree i)
subKind lhs rhs
    | all (CT.isFundamental . atype) [lhs, rhs] = Just $ ATNode ATSub (CT.conversion (atype lhs) (atype rhs)) lhs rhs
    | isJust (CT.deref $ atype lhs) && CT.isFundamental (atype rhs) = Just $ ATNode ATSubPtr (atype lhs) lhs rhs
    | all (isJust . CT.deref . atype) [lhs, rhs] = Just $ ATNode ATPtrDis (atype lhs) lhs rhs
    | otherwise = Nothing

-- | `add` indicates \(\eqref{eq:first}\) among the comments of `inners`.
add :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
add xs atn scp = (>>=) (term xs atn scp) $ uncurry3 add'
    where
        add' (cur@(_, HT.TKReserved "+"):ys) era ars = (>>=) (term ys era ars) $ \zz -> 
            maybe' (Left ("invalid operands", cur)) (addKind era $ snd3 zz) $ \nat -> uncurry3 id $ first3 add' $ second3 (const nat) zz
        add' (cur@(_, HT.TKReserved "-"):ys) era ars = (>>=) (term ys era ars) $ \zz -> 
            maybe' (Left ("invalid operands", cur)) (subKind era $ snd3 zz) $ \nat -> uncurry3 id $ first3 add' $ second3 (const nat) zz
        add' ert erat ars = Right (ert, erat, ars)

-- | `term` indicates \(\eqref{eq:second}\) amont the comments of `inners`.
term :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
term = inners cast [("*", ATMul), ("/", ATDiv), ("%", ATMod)]

-- | `cast` indicates \(\eqref{eq:fourteenth}\) amont the comments of `inners`.
cast :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
cast (cur@(_, HT.TKReserved "("):xs) at scp = flip (either (const $ unary (cur:xs) at scp)) (takeTypeName xs scp) $ \case
    (t, (_, HT.TKReserved ")"):xs') -> second3 (flip (ATNode ATCast t) ATEmpty) <$> cast xs' at scp
    _ -> Left ("The token ')' corresponding to '(' is expected", cur)
cast xs at scp = unary xs at scp

-- | `unary` indicates \(\eqref{eq:fourth}\) amount the comments of `inners`.
unary :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
unary ((_, HT.TKReserved "+"):xs) at scp = cast xs at scp
unary ((_, HT.TKReserved "-"):xs) at scp = second3 (ATNode ATSub (CT.SCAuto CT.CTInt) (ATNode (ATNum 0) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty)) <$> cast xs at scp
unary ((_, HT.TKReserved "!"):xs) at scp = second3 (flip (ATNode ATNot $ CT.SCAuto CT.CTInt) ATEmpty) <$> cast xs at scp
unary ((_, HT.TKReserved "~"):xs) at scp = second3 (flip (ATNode ATBitNot $ CT.SCAuto CT.CTInt) ATEmpty) <$> cast xs at scp
unary ((_, HT.TKReserved "&"):xs) at scp = second3 (\x -> let ty = if CT.isCTArray (atype x) then fromJust $ CT.deref (atype x) else atype x in (ATNode ATAddr $ CT.picksc ty $ CT.CTPtr $ CT.fromsc ty) x ATEmpty) <$> cast xs at scp
unary (cur@(_, HT.TKReserved "*"):xs) at !scp = (>>=) (cast xs at scp) $ \(ert, erat, erscp) -> 
    maybe' (Left ("invalid pointer dereference", cur)) (CT.deref $ atype erat) $ \y -> case CT.fromsc y of
        CT.CTVoid -> Left ("void value not ignored as it ought to be", cur)
        _ -> Right (ert, ATNode ATDeref y erat ATEmpty, erscp)
unary ((_, HT.TKReserved "++"):xs) at scp = second3 (\x -> ATNode ATPreInc (atype x) x ATEmpty) <$> unary xs at scp
unary ((_, HT.TKReserved "--"):xs) at scp = second3 (\x -> ATNode ATPreDec (atype x) x ATEmpty) <$> unary xs at scp
unary xs at scp = either Left (uncurry3 f) $ factor xs at scp
    where
        f (cur@(_, HT.TKReserved "["):xs') erat !erscp = (>>=) (expr xs' erat erscp) $ \(ert', erat', erscp') -> case ert' of
            (_, HT.TKReserved "]"):xs'' -> maybe' (Left ("invalid operands", cur)) (addKind erat erat') $ \erat'' ->
                maybe' (Left ("subscripted value is neither array nor pointer nor vector", if null xs then HT.emptyToken else head xs)) 
                    (CT.deref $ atype erat'') $ \t -> f xs'' (ATNode ATDeref t erat'' ATEmpty) erscp'
            _ -> Left $ if null ert' then ("expected expression after '[' token", cur) else ("expected expression before '" <> tshow (snd (head ert')) <> "' token", head ert')
        f (cur@(_, HT.TKReserved "."):xs') erat !erscp 
            | CT.isCTStruct (atype erat) = if null xs' then Left ("expected identifier at end of input", cur) else case head xs' of 
                (_, HT.TKIdent ident) -> maybe' (Left ("no such member", cur)) (CT.lookupMember ident (CT.fromsc $ atype erat)) $ \mem ->
                    f (tail xs') (ATNode (ATMemberAcc mem) (CT.SCAuto $ CT.smType mem) erat ATEmpty) erscp
                _ -> Left ("expected identifier after '.' token", cur)
            | otherwise = Left ("request for a member in something not a structure or union", cur)
        f (cur@(_, HT.TKReserved "->"):xs') erat !erscp
            | maybe False CT.isCTStruct $ CT.deref (atype erat) = if null xs' then Left ("expected identifier at end of input", cur) else case head xs' of
                (_, HT.TKIdent ident) -> maybe' (Left ("no such member", cur)) (CT.lookupMember ident (CT.fromsc $ fromJust $ CT.deref $ atype erat)) $ \mem ->
                    f (tail xs') (ATNode (ATMemberAcc mem) (CT.SCAuto $ CT.smType mem) (ATNode ATDeref (CT.SCAuto $ CT.smType mem) erat ATEmpty) ATEmpty) erscp
                _ -> Left ("expected identifier after '->' token", cur)
            | otherwise = Left ("invalid type argument of '->'" <> if CT.isCTUndef (atype erat) then "" else " (have '" <> tshow (atype erat) <> "')", cur)
        f ((_, HT.TKReserved "++"):xs') erat !erscp = f xs' (ATNode ATPostInc (atype erat) erat ATEmpty) erscp
        f ((_, HT.TKReserved "--"):xs') erat !erscp = f xs' (ATNode ATPostDec (atype erat) erat ATEmpty) erscp
        f ert erat !erscp = Right (ert, erat, erscp)

-- | `factor` indicates \(\eqref{eq:third}\) amount the comments of `inners`.
factor :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ATree i -> ConstructionData i -> ASTConstruction i
factor [] atn !scp = Right ([], atn, scp)
factor ((_, HT.TKReserved "("):xs@((_, HT.TKReserved "{"):_)) _ !scp = maybe' (Left (internalCE, head xs)) (takeBrace "{" "}" xs) $ -- for statement expression (GNU extension: <https://gcc.gnu.org/onlinedocs/gcc/Statement-Exprs.html>)
    either (Left . ("the statement expression is not closed",)) $ \(sctk, ds) -> case ds of
        (_, HT.TKReserved ")"):ds' -> runST $ do
            eri <- newSTRef Nothing
            v <- newSTRef $ succNest scp
            lastA <- newSTRef ATEmpty 
            mk <- flip unfoldrM (init $ tail sctk) $ \ert -> if null ert then return Nothing else do
                erscp <- readSTRef v
                flip (either $ \err -> Nothing <$ writeSTRef eri (Just err)) (stmt ert ATEmpty erscp) $ \(ert', erat', erscp') -> 
                    Just (erat', ert') <$ (writeSTRef v erscp' >> when (case erat' of ATEmpty -> False; _ -> True) (writeSTRef lastA erat'))
            (>>=) (readSTRef eri) $ flip maybe (return . Left) $ do
                v' <- readSTRef v
                flip fmap (readSTRef lastA) $ \case
                        (ATNode ATExprStmt _ lhs _) -> Right (ds', ATNode (ATStmtExpr (init mk ++ [lhs])) (atype lhs) ATEmpty ATEmpty, fallBack scp v')
                        _ -> Left ("void value not ignored as it ought to be. the statement expression starts here:", head xs)
        _ -> Left $ if null sctk then ("expected ')' token. the statement expression starts here: ", head xs) else
            ("expected ')' token after '" <> tshow (snd $ last sctk) <> "' token", last sctk)
factor (cur@(_, HT.TKReserved "("):xs) atn !scp = (>>=) (expr xs atn scp) $ \(ert, erat, erscp) -> case ert of -- for (expr)
    (_, HT.TKReserved ")"):ys -> Right (ys, erat, erscp)
    ert' -> Left $ expectedMessage ")" cur ert'
factor ((_, HT.TKNum n):xs) _ !scp = Right (xs, ATNode (ATNum n) (CT.SCAuto $ CT.CTLong CT.CTInt) ATEmpty ATEmpty, scp) -- for numbers
factor (cur@(_, HT.TKIdent v):(_, HT.TKReserved "("):(_, HT.TKReserved ")"):xs) _ !scp = case lookupFunction v scp of -- for no arguments function call
    Nothing -> Right (xs, ATNode (ATCallFunc v Nothing) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty, pushWarn ("the function '" <> v <> "' is not declared.") cur scp)
    Just fn -> Right (xs, ATNode (ATCallFunc v Nothing) (PSF.fntype fn) ATEmpty ATEmpty, scp)
factor (cur1@(_, HT.TKIdent v):cur2@(_, HT.TKReserved "("):xs) _ scp = maybe' (Left (internalCE, cur1)) (takeBrace "(" ")" (cur2:xs)) $ -- for some argumets function call
    either (Left . ("invalid function call",)) $ \(fsec, ds) -> case lookupFunction v scp of
        Nothing -> f fsec ds (pushWarn ("The function '" <> tshow (snd cur1) <> "' is not declared.") cur1 scp) $ CT.SCAuto CT.CTInt
        Just fn -> f fsec ds scp (PSF.fntype fn) 
    where
        f fsec ds scp' t = maybe' (Left ("invalid function call", cur1)) (takeExps (cur1:fsec)) $ \exps -> runST $ do
            mk <- newSTRef scp'
            expl <- forM exps $ \etk -> readSTRef mk >>= either (return . Left) (\(_, erat, ervar) -> Right erat <$ writeSTRef mk ervar) . expr etk ATEmpty
            if any isLeft expl then return $ Left $ head $ lefts expl else do
                scp'' <- readSTRef mk
                return $ Right (ds, ATNode (ATCallFunc v (Just $ rights expl)) t ATEmpty ATEmpty, scp'')
factor ((_, HT.TKSizeof):cur@(_, HT.TKReserved "("):xs) atn scp = case takeTypeName xs scp of
    Left _ -> second3 (\x -> ATNode (ATNum (fromIntegral $ CT.sizeof $ atype x)) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty) <$> unary (cur:xs) atn scp -- for `sizeof(variable)`
    Right (t, (_, HT.TKReserved ")"):ds) -> Right (ds, ATNode (ATNum (fromIntegral $ CT.sizeof t)) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty, scp) -- for `sizeof(type)`
    Right _ -> Left ("The token ')' corresponding to '(' is expected", cur) 
factor ((_, HT.TKSizeof):xs) atn !scp = second3 (\x -> ATNode (ATNum (fromIntegral $ CT.sizeof $ atype x)) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty) <$> unary xs atn scp -- for `sizeof variable` -- TODO: the type of sizeof must be @size_t@
factor (cur@(_, HT.TKAlignof):xs) atn !scp = (>>=) (unary xs atn scp) $ \(ert, erat, erscp) -> 
    if CT.isCTUndef (atype erat) then Left ("_Alignof must be an expression or type", cur) else Right (ert, ATNode (ATNum (fromIntegral $ CT.alignof $ atype erat)) (CT.SCAuto CT.CTInt) ATEmpty ATEmpty, erscp) -- Note: Using alignof for expressions is a non-standard feature of C11
factor (cur@(_, HT.TKString slit):xs) _ !scp = uncurry (xs,,) <$> addLiteral (CT.SCAuto $ CT.CTArray (fromIntegral $ B.length slit) CT.CTChar) cur scp -- for literals
factor (cur@(_, HT.TKIdent ident):xs) _ !scp = case lookupVar ident scp of
    FoundGVar (PV.GVar t) -> Right (xs, ATNode (ATGVar t ident) t ATEmpty ATEmpty, scp) -- for declared global variable
    FoundLVar (PV.LVar t o _) -> Right (xs, ATNode (ATLVar t o) t ATEmpty ATEmpty, scp) -- for declared local variable
    FoundEnum (SE.Enumerator val _) -> Right (xs, ATNode (ATNum val) (CT.SCAuto $ CT.CTLong CT.CTInt) ATEmpty ATEmpty, scp) -- for declared enumerator
    NotFound -> Left ("The '" <> ident <> "' is undefined variable", cur)
factor ert _ _ = Left (if null ert then "unexpected token in program" else "unexpected token '" <> tshow (snd (head ert)) <> "' in program", if null ert then HT.emptyToken else head ert)

{-# INLINE parse #-}
-- | Constructs the abstract syntax tree based on the list of token strings.
-- if construction fails, `parse` returns the error message and the token at the error location.
-- Otherwise, `parse` returns a list of abstract syntax trees, a set of global variables, and a list of literals.
parse :: (Show i, Read i, Integral i, Bits i) => [HT.TokenLC i] -> ASTResult i
parse = fmap (\(ast, sc) -> (warns sc, ast, PV.globals $ vars $ scope sc, PV.literals $ vars $ scope sc)) . flip program initConstructionData

-- | `stackSize` returns the stack size of variable per function.
stackSize :: (Show i, Integral i) => ATree i -> Natural
stackSize (ATNode (ATDefFunc _ args) _ body _) = let ms = f body $ maybe S.empty (foldr (\(ATNode (ATLVar t x) _ _ _) acc -> S.insert (t, x) acc) S.empty) args in
    if S.size ms == 1 then toNatural $ flip CT.alignas 8 $ toInteger $ CT.sizeof $ fst $ head (S.toList ms) else toNatural $ flip CT.alignas 8 $ uncurry (+) $
        first (toInteger . CT.sizeof . fst) $ second (fromIntegral . snd) $ dupe $ foldl' (\acc x -> if snd acc < snd x then x else acc) (CT.SCUndef CT.CTUndef, 0) $ S.toList ms
    where
        f ATEmpty !s = s
        f (ATNode (ATCallFunc _ (Just arg)) t l r) !s = f (ATNode (ATBlock arg) t l r) s
        f (ATNode (ATLVar t x) _ l r) !s = let i = S.insert (t, x) s in f l i `S.union` f r i
        f (ATNode (ATBlock xs) _ l r) !s = let i = foldr (S.union . (`f` s)) s xs in f l i `S.union` f r i
        f (ATNode (ATStmtExpr xs) t l r) !s = f (ATNode (ATBlock xs) t l r) s 
        f (ATNode (ATFor xs) _ l r) !s = let i = foldr (S.union . flip f s . fromATKindFor) S.empty xs in f l i `S.union` f r i
        f (ATNode (ATNull x) _ _ _) !s = f x s
        f (ATNode _ _ l r) !s = f l s `S.union` f r s
stackSize _ = 0

