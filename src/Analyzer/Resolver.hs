{-# Language OverloadedStrings #-}
{-# Language LambdaCase #-}
{-# Language FlexibleContexts #-}

module Analyzer.Resolver where

import Data.Text (Text, pack, take, toUpper)
import Data.Maybe
import Control.Monad.State
import Control.Monad.Reader
import Control.Monad.Except
import qualified Data.Map as M
import qualified Data.Set as S

import Analyzer.AnalyzerError
import Syntax
import SyntaxInfo
import Type
import Name

type Resolve = ExceptT AnalyzerError (ReaderT [Text] (State ResolveState))
data ResolveState = ResolveState
    { nameSet :: S.Set Name
    , pubMap :: M.Map Name Bool
    , curMod :: Maybe UntypedModule 
    , extraSet :: S.Set Name -- probably not the best way to check for duplicate top levels but works
    , tmpScopeCount :: Int
    , importsMap :: M.Map [Text] [Import]
    } deriving (Show)

resolveProgram :: UntypedProgram -> Either AnalyzerError UntypedProgram
resolveProgram prog = evalState (runReaderT (runExceptT (traverse resolveModule prog)) []) initResolveState
    where
        initResolveState = ResolveState {
            nameSet = initNameSet,
            pubMap = initPubMap,
            curMod = Nothing,
            extraSet = S.empty,
            tmpScopeCount = 0,
            importsMap = initImportsMap
        }
        initPubMap = M.fromList $ concatMap (\mod -> concatMap (topLvlEntry mod) (modTopLvls mod)) prog
        topLvlEntry _ TLExtern {} = []
        topLvlEntry mod tl = [(head $ topLvlToName mod tl, isTopLvlPub tl)]
        initImportsMap = M.fromList $ map (\mod -> (getModFullName mod, modImports mod)) prog
        initNameSet = S.fromList $ concatMap (\mod -> concatMap (topLvlToName mod) (modTopLvls mod)) prog
        -- ^ contains all of the top level declarations of each module, this is so mutual recursion works

resolveModule :: UntypedModule -> Resolve UntypedModule
resolveModule mod = do
    state <- get
    put (state { curMod = Just mod })
    resolvedTopLvls <- traverse resolveTopLvl (modTopLvls mod)
    return (mod { modTopLvls = resolvedTopLvls })

resolveTopLvl :: UntypedTopLvl -> Resolve UntypedTopLvl
resolveTopLvl = \case
    TLFunc info isPub isOper name@(Unqualified unqual) params typeAnnot expr -> do
        fullName <- topLvlDefinition info unqual
        typeAnnot' <- resolveTypeAnnot info typeAnnot

        local (++ [unqual]) (do
            let (pnames, pannots) = unzip params
            mapM_ insertNameToSet pnames
            pannots' <- traverse (resolveTypeAnnot info) pannots
            expr' <- resolveExpr expr
            return (TLFunc info isPub isOper fullName (zip pnames pannots') typeAnnot' expr'))

    TLType info isPub name@(Unqualified unqual) tvars typ -> do
        topLvlDefinition info unqual
        TLType info isPub name tvars <$> resolveType info typ

    tl@TLExtern {} -> return tl
    _ -> undefined
    where
        topLvlDefinition info unqual = do
            eset <- gets extraSet
            scope <- prependModulePath []
            let fullName = Qualified scope unqual
            when (fullName `S.member` eset)
                $ throwError (GenericAnalyzerError (syntaxInfoSourcePos info) ("Redefinition of " ++ show fullName))
            state <- get
            put (state { extraSet = S.insert fullName eset })
            return fullName

resolveDecl :: UntypedDecl -> Resolve UntypedDecl
resolveDecl = \case
    DStmt stmt -> DStmt <$> resolveStmt stmt
    DVar info isMut name typeAnnot expr -> do
        let Unqualified unqual = name
        expr' <- resolveExpr expr
        typeAnnot' <- resolveTypeAnnot info typeAnnot
        checkNameDuplicate info unqual
        fullName <- insertNameToSet unqual
        return (DVar info isMut fullName typeAnnot' expr')

resolveStmt :: UntypedStmt -> Resolve UntypedStmt
resolveStmt = \case
    SExpr expr -> SExpr <$> resolveExpr expr
    SRet expr -> SRet <$> resolveExpr expr
    SWhile info cond body -> SWhile info <$> resolveExpr cond <*> resolveExpr body

resolveExpr :: UntypedExpr -> Resolve UntypedExpr
resolveExpr = \case
    lit@ELit {} -> return lit
    EVar info _ types name -> EVar info () types <$> resolveName info name
    EAssign info _ lhs rhs -> do
        lhs' <- resolveExpr lhs
        rhs' <- resolveExpr rhs
        return (EAssign info () lhs' rhs')
    EBlock info _ decls expr -> do
        tscope <- tmpScope
        local (++ [tscope]) (do
            decls' <- traverse resolveDecl decls
            expr' <- resolveExpr expr
            return (EBlock info () decls' expr'))
    EIf info _ cond exprA exprB -> do
        cond' <- resolveExpr cond
        exprA' <- resolveExpr exprA
        exprB' <- resolveExpr exprB
        return (EIf info () cond' exprA' exprB')
    EMatch info _ expr branches -> do
        expr' <- resolveExpr expr
        return (EMatch info () expr' branches)
    EBinOp info _ name lhs rhs -> do
        lhs' <- resolveExpr lhs
        rhs' <- resolveExpr rhs
        name' <- resolveName info name
        return (EBinOp info () name' lhs' rhs')
    EUnaOp info _ name expr -> do
        expr' <- resolveExpr expr
        name' <- resolveName info name
        return (EUnaOp info () name' expr')
    EClosure info _ cvars params tann expr -> do
        undefined
    ECall info _ expr args -> do
        expr' <- resolveExpr expr
        args' <- traverse resolveExpr args
        return (ECall info () expr' args')
    ECast info typ expr -> do
        typ' <- resolveType info typ
        expr' <- resolveExpr expr
        return (ECast info typ' expr')
            
resolveType :: SyntaxInfo -> Type -> Resolve Type
resolveType info = \case
    typ@(TConst name@(Unqualified unqual)) | unqual `elem` baseTypes -> return typ
    typ@(TConst name) -> TConst <$> resolveName info name
    TApp typ typs -> TApp <$> resolveType info typ <*> traverse (resolveType info) typs
    TArrow typs typ -> TArrow <$> traverse (resolveType info) typs <*> resolveType info typ
    other -> return other
    where
        baseTypes =
            ["i8", "i16", "i32", "i64",
            "u8", "u16", "u32", "u64",
            "f32", "f64",
            "char", "bool", "unit"]

resolveTypeAnnot :: SyntaxInfo -> TypeAnnot -> Resolve TypeAnnot
resolveTypeAnnot info annot =
    case annot of
        Just typ -> Just <$> resolveType info typ
        Nothing -> return Nothing

checkNameDuplicate :: SyntaxInfo -> Text -> Resolve ()
checkNameDuplicate info name = do
    curLocalScope <- ask
    set <- gets nameSet
    fullScope <- prependModulePath curLocalScope
    when (Qualified fullScope name `S.member` set)
        $ throwError (GenericAnalyzerError (syntaxInfoSourcePos info) ("Redefinition of " ++ show name))

insertNameToSet :: Text -> Resolve Name
insertNameToSet name = do
    curLocalScope <- ask
    fullScope <- prependModulePath curLocalScope
    set <- gets nameSet
    state <- get
    let fullName = Qualified fullScope name
    put (state { nameSet = S.insert fullName set })
    return fullName

resolveName :: SyntaxInfo -> Name -> Resolve Name
resolveName info name =
    case name of
        Unqualified unqual -> qualifyName info unqual
        Qualified {} -> name <$ verifyNameExists info name

verifyNameExists :: SyntaxInfo -> Name -> Resolve ()
verifyNameExists info (Unqualified unqual) =
    throwError (GenericAnalyzerError (syntaxInfoSourcePos info) "Attempt to verify unqualified name")
verifyNameExists info name@Qualified {} = do
    set <- gets nameSet
    unless (name `S.member` set) $ throwError (GenericAnalyzerError (syntaxInfoSourcePos info) ("Undefined " ++ show name))

qualifyName :: SyntaxInfo -> Text -> Resolve Name
qualifyName info name = do
    curLocalScope <- ask
    qualifyNameHelper curLocalScope >>= \case
        Just foundName -> return foundName
        Nothing -> do
            mod <- gets (fromJust . curMod) -- curMod should be a Just by this point
            set <- gets nameSet
            -- check imported modules
            let imports = modImports mod
            allImports <- (imports ++) . concat <$> traverse gatherAllPubImports imports
            let exists = concatMap (\imp -> let fullName = Qualified (snd imp) name in [fullName | fullName `S.member` set]) allImports
            isPubs <- gets pubMap
            case filter (\n -> fromMaybe False (M.lookup n isPubs)) exists of
                [] -> throwError (GenericAnalyzerError (syntaxInfoSourcePos info) ("Undefined " ++ show name))
                [onlyOne] -> return onlyOne
                multiple -> throwError (GenericAnalyzerError (syntaxInfoSourcePos info) ("Multiple definitions found: " ++ show multiple))
    where
        qualifyNameHelper localScope = do
            set <- gets nameSet
            fullScope <- prependModulePath localScope
            if Qualified fullScope name `S.member` set
                then (return . Just) (Qualified fullScope name)
                else case localScope of
                    [] -> return Nothing
                    _ -> qualifyNameHelper (init localScope)

gatherAllPubImports :: Import -> Resolve [Import]
gatherAllPubImports imp = do
    impMap <- gets importsMap
    let parentImps = fromMaybe [] (M.lookup (snd imp) impMap)
    let pubParentImps = filter fst parentImps
    toAppend <- traverse gatherAllPubImports pubParentImps
    return (pubParentImps ++ concat toAppend)

prependModulePath :: [Text] -> Resolve [Text]
prependModulePath scope = do
    mod <- gets (fromJust . curMod)
    return (modPath mod ++ modName mod : scope)

tmpScope :: Resolve Text
tmpScope = do
    state <- get
    put (state { tmpScopeCount = tmpScopeCount state + 1 })
    return . pack . ('_':) $ ([1..] >>= flip replicateM ['a'..'z']) !! tmpScopeCount state
