{-# Language OverloadedStrings #-}
{-# Language LambdaCase #-}
{-# Language TupleSections #-}

module Analyzer (analyze) where

import Data.Text (Text, pack, unpack)
import Data.Maybe
import Data.Functor.Identity
import Data.Foldable (traverse_)
import qualified Data.Map as M
import qualified Data.Set as S
import Control.Monad.RWS
import Control.Monad.Except

import Debug.Trace

import Syntax
import Type
import Substitution

type AEnv = M.Map Text (TypeScheme, Bool)
type Infer = RWST () [Constraint] InferState (Except String)

data InferState = InferState
    { environment :: AEnv
    , freshCount :: Int
    , topLvlTmps :: M.Map Text Type
    , mainExists :: Bool
    } deriving (Show)

analyze :: UntypedModule -> Either String TypedModule
analyze = runInfer

-- Type Inference
constrain :: Constraint -> Infer ()
constrain = tell . (: [])

fresh :: Infer Type
fresh = do
    state <- get
    let count = freshCount state
    put (state { freshCount = count + 1 })
    (return . TVar . TV . pack) (names !! count)
    where
        names = map ('_' :) ([1..] >>= flip replicateM ['a'..'z'])

generalize :: AEnv -> Type -> TypeScheme
generalize env t = Forall (S.toList vs) t
    where vs = tvs t `S.difference` tvs (map fst $ M.elems env)

instantiate :: TypeScheme -> Infer Type
instantiate (Forall vs t) = do
    nvs <- traverse (const fresh) vs
    let sub = M.fromList (zip vs nvs)
    return (apply sub t)

runInfer :: UntypedModule -> Either String TypedModule
runInfer mod =
    let defaultState = InferState { environment = M.empty, freshCount = 0, topLvlTmps = M.empty, mainExists = False } in
    case runIdentity $ runExceptT $ runRWST (inferModule mod) () defaultState of
        Left err -> Left err
        Right (mod', _, consts) -> do
            sub <- runSolve consts
            return $ fmap (fmap $ apply sub) mod'

inferModule :: UntypedModule -> Infer TypedModule
inferModule topLvls = do
    traverse_ insertTmpVars topLvls
    traverse inferTopLvl topLvls

insertTmpVars :: UntypedTopLvl -> Infer ()
insertTmpVars = \case
    TLFunc _ name _ _ _-> do
        var <- fresh
        state <- get
        put (state { topLvlTmps = M.insert name var (topLvlTmps state) })

    TLOper _ _ oper _ _ _ -> do
        var <- fresh
        state <- get
        put (state { topLvlTmps = M.insert oper var (topLvlTmps state) })

    TLType typeName typeParams cons -> insertValueCons typeName typeParams cons

    TLExtern name ptypes rtype -> insertEnv (name, (Forall [] $ TFunc ptypes rtype, False))

insertValueCons :: Text -> [TVar] -> [(Text, [Type])] -> Infer ()
insertValueCons _ _ [] = return ()
insertValueCons typeName typeParams ((conName, conTypes) : restCons) = do
    let typeParams' = map TVar typeParams
    let varsTypeParams = tvs typeParams'
    let varsCon = tvs conTypes

    env <- gets environment
    if (varsTypeParams `S.intersection` varsCon) /= varsCon
        then let undefineds = S.toList (varsCon `S.difference` varsTypeParams)
             in throwError ("Undefined type variables " ++ show undefineds)
        else let scheme = case conTypes of
                    [] -> Forall [] (TCon typeName typeParams') -- generalize env (TParam typeNam)
                    _ -> Forall [] (TFunc conTypes (TCon typeName typeParams')) --generalize env (TFunc (TParam ttypeParams' (TCon typeName))
             in insertEnv (conName, (scheme, False)) *> insertValueCons typeName typeParams restCons

inferTopLvl :: UntypedTopLvl -> Infer TypedTopLvl
inferTopLvl = \case
    TLFunc _ name params rtann body -> do
        alreadyDefined <- exists name
        if alreadyDefined then throwError ("Function '" ++ unpack name ++ "' already defined")
        else do
            when (name == "main") (do
                state <- get
                put (state { mainExists = True }))
            (body', typ) <- inferFn name params rtann body
            return (TLFunc typ name params rtann body')

    TLOper _ opdef oper params rtann body -> do
        alreadyDefined <- exists oper
        if alreadyDefined then throwError ("Operator '" ++ unpack oper ++ "' already defined")
        else do
            (body', typ) <- inferFn oper params rtann body
            return (TLOper typ opdef oper params rtann body')

    TLType typeName typeParams cons -> return (TLType typeName typeParams cons)
    TLExtern name ptypes rtype -> return (TLExtern name ptypes rtype)

inferFn :: Text -> Params -> TypeAnnot -> UntypedExpr -> Infer (TypedExpr, Type)
inferFn name params rtann body = do
    let (pnames, panns) = unzip params
    ptypes <- traverse (const fresh) params
    let ptypesSchemes = map ((, False) . Forall []) ptypes
    let nenv = M.fromList (zip pnames ptypesSchemes)
    ((body', rtype), consts) <- listen (scoped (`M.union` nenv) (inferExpr body))

    subst <- liftEither (runSolve consts)
    env <- ask
    let typ = apply subst (TFunc ptypes rtype)
        scheme = Forall [] typ -- generalize env typ -- TODO: generalize for parametric polymorphism

    let (TFunc ptypes' rtype') = typ
    when (isJust rtann) (constrain $ CEqual rtype' (fromJust rtann))
    sequence_ [when (isJust pann) (constrain $ CEqual ptype (fromJust pann)) | (ptype, pann) <- zip ptypes' panns]

    retStmtTypes <- searchReturnsExpr body'
    traverse_ (constrain . CEqual rtype') retStmtTypes

    state <- get
    let tmpsEnv = topLvlTmps state
    put (state {topLvlTmps = M.delete name tmpsEnv})
    
    insertEnv (name, (scheme, False)) -- already scoped by block
    return (body', typ)

inferDecl :: UntypedDecl -> Infer TypedDecl
inferDecl = \case
    DVar _ isMut name tann expr -> do
        alreadyDefined <- exists name 
        if alreadyDefined then throwError ("Variable '" ++ unpack name ++ "' already defined")
        else do
            ((expr', etype), consts) <- listen (inferExpr expr)
            subst <- liftEither (runSolve consts)
            env <- ask
            let typ = apply subst etype
                scheme = Forall [] typ -- TODO: generalize
            when (isJust tann) (constrain $ CEqual typ (fromJust tann))
            insertEnv (name, (scheme, isMut))
            return (DVar typ isMut name tann expr')
    DStmt s -> DStmt <$> inferStmt s

inferStmt :: UntypedStmt -> Infer TypedStmt
inferStmt = \case
    SRet expr -> do
        (expr', _) <- inferExpr expr
        return (SRet expr')
    SWhile cond body -> do
        (cond', ctype) <- inferExpr cond
        (body', _) <- inferExpr body
        constrain (CEqual ctype TBool)
        return (SWhile cond' body')
    SExpr expr -> do
        (expr', _) <- inferExpr expr
        return (SExpr expr')

inferExpr :: UntypedExpr -> Infer (TypedExpr, Type)
inferExpr = \case
    ELit _ lit -> let typ = inferLit lit in return (ELit typ lit, typ)

    EVar _ name -> lookupType name >>= \typ -> return (EVar typ name, typ)

    EAssign _ l r -> do
        (l', ltype) <- inferExpr l
        (r', rtype) <- inferExpr r
        constrain (CEqual ltype rtype)
        let expr' = EAssign ltype l' r'
        case l' of
            EVar _ name -> do
                isMut <- lookupMut name
                unless isMut (throwError $ "Cannot assign to immutable variable " ++ unpack name)
                return (expr', ltype)
            EDeref _ _ -> return (expr', ltype)
            _ -> throwError "Cannot assign to non-lvalue"

    EBlock _ origDecls expr -> do
        (decls', expr', etype) <- scoped id (do
            ds <- traverse inferDecl origDecls
            (ex, et) <- inferExpr expr
            return (ds, ex, et))
        return (EBlock etype decls' expr', etype)

    EIf _ cond texpr fexpr -> do
        (cond', ctype) <- inferExpr cond
        (texpr', ttype) <- inferExpr texpr
        (fexpr', ftype) <- inferExpr fexpr
        constrain (CEqual ctype TBool)
        constrain (CEqual ttype ftype)
        return (EIf ttype cond' texpr' fexpr', ttype)

    EMatch _ mexpr branches -> do
        (mexpr', mtype) <- inferExpr mexpr
        (branches', btypes) <- unzip <$> traverse (inferBranch mtype) branches
        case btypes of
            [] -> throwError "Empty match expression"
            (btype : rest) -> (EMatch btype mexpr' branches', btype) <$ traverse_ (constrain . CEqual btype) rest

    EBinOp _ oper a b -> do
        (a', at) <- inferExpr a
        (b', bt) <- inferExpr b
        case oper of
            _ | oper `elem` ["+", "-", "*", "/"] -> do -- TODO
                return (EBinOp at oper a' b', at)
            _ | oper `elem` ["==", "!=", ">", "<", ">=", "<="] -> do
                return (EBinOp TBool oper a' b', TBool)
            _ | oper `elem` ["||", "&&"] -> do
                constrain (CEqual at TBool)
                constrain (CEqual bt TBool)
                return (EBinOp TBool oper a' b', TBool)
            _ -> do
                opt <- lookupType oper
                rt <- fresh
                let ft = TFunc [at, bt] rt
                constrain (CEqual opt ft)
                return (EBinOp rt oper a' b', rt)

    EUnaOp _ oper expr -> do
        opt <- lookupType oper
        (a', at) <- inferExpr expr
        rt <- fresh
        constrain (CEqual opt (TFunc [at] rt))
        return (EUnaOp rt oper a', rt)

    EClosure _ closedVars params rtann body -> throwError "Closures not implemented yet"

    ECall _ expr args -> do
        (a', at) <- inferExpr expr
        (bs', bts) <- unzip <$> traverse inferExpr args
        rt <- fresh
        constrain (CEqual at (TFunc bts rt))
        return (ECall rt a' bs', rt)

    ECast _ targ expr -> do
        (expr', etype) <- inferExpr expr
        return (ECast targ targ expr', targ) -- TODO

    EDeref _ expr -> do
        (expr', etype) <- inferExpr expr
        tv <- fresh
        constrain (CEqual etype (TPtr tv))
        return (EDeref tv expr', tv)

    ERef _ expr -> do
        (expr', etype) <- inferExpr expr
        case expr' of
            EVar _ s -> return (ERef (TPtr etype) expr', TPtr etype)
            _ -> throwError "Cannot reference non-variable"

    ESizeof _ arg -> do
        arg' <- case arg of
            Left t -> return (Left t)
            Right e -> Right . fst <$> inferExpr e
        return (ESizeof TInt32 arg', TInt32)

inferLit :: Lit -> Type
inferLit = \case
    LInt _ -> TInt32
    LFloat _ -> TFloat64
    LString _ -> TStr
    LChar _ -> TChar
    LBool _ -> TBool
    LUnit -> TUnit

inferBranch :: Type -> (Pattern, UntypedExpr) -> Infer ((Pattern, TypedExpr), Type)
inferBranch mt (pat, expr) = do
    (pt, vars) <- inferPattern pat
    let vars' = map (\(s, ts) -> (s, (ts, False))) vars
    constrain (CEqual pt mt)
    (expr', et) <- scoped (M.fromList vars' `M.union`) (inferExpr expr)
    return ((pat, expr'), et)

inferPattern :: Pattern -> Infer (Type, [(Text, TypeScheme)])
inferPattern (PVar name) = do
    ptype <- fresh
    pure (ptype, [(name, Forall [] ptype)])
inferPattern (PLit lit) = return (inferLit lit, [])
inferPattern PWild = do
    ptype <- fresh
    return (ptype, [])
inferPattern (PCon conName binds) = do
    ptypes <- traverse (const fresh) binds
    let res = [(bind, Forall [] ptype) | (bind, ptype) <- zip binds ptypes]
    conType <- lookupType conName
    t <- fresh
    let conType' = case binds of
            [] -> t
            _ -> TFunc ptypes t
    constrain (CEqual conType' conType)
    return (t, res)

-- Environment helpers
scoped :: (AEnv -> AEnv) -> Infer a -> Infer a
scoped fn m = do
    state <- get
    let env = environment state
    put (state { environment = fn env })
    res <- m
    state' <- get
    put (state' { environment = env })
    return res

insertEnv :: (Text, (TypeScheme, Bool)) -> Infer ()
insertEnv (name, info) = do
    state <- get
    put (state { environment = M.insert name info (environment state) })

lookupVar :: Text -> Infer (TypeScheme, Bool)
lookupVar name = do
    env <- gets environment
    case M.lookup name env of
        Just v -> return v
        Nothing -> do -- check temp env for top levels
            tmpsEnv <- gets topLvlTmps
            case M.lookup name tmpsEnv of
                Just v -> return (Forall [] v, False)
                Nothing -> throwError ("Unknown variable " ++ unpack name)

lookupType :: Text -> Infer Type
lookupType name = lookupVar name >>= instantiate . fst

lookupMut :: Text -> Infer Bool
lookupMut name = snd <$> lookupVar name

exists :: Text -> Infer Bool
exists name = isJust . M.lookup name <$> gets environment -- Doesn't check temp env for top levels

-- Unification
type Solve = ExceptT String Identity

compose :: Substitution -> Substitution -> Substitution
compose a b = M.map (apply a) b `M.union` a

unify :: Type -> Type -> Solve Substitution
unify a b | a == b = return M.empty
unify (TVar v) t = bind v t
unify t (TVar v) = bind v t
unify a@(TCon c1 ts1) b@(TCon c2 ts2)
    | c1 /= c2 = throwError $ "Type mismatch " ++ show a ++ " ~ " ++ show b
    | otherwise = unifyMany ts1 ts2
unify a@(TFunc pts rt) b@(TFunc pts2 rt2)
    | length pts /= length pts2 = throwError $ "Type mismatch " ++ show a ++ " ~ " ++ show b
    | otherwise = unifyMany (rt : pts) (rt2 : pts2)
unify a@(TPtr t) b@(TPtr t2) = unify t t2
unify a b = throwError $ "Type mismatch " ++ show a ++ " ~ " ++ show b

unifyMany :: [Type] -> [Type] -> Solve Substitution
unifyMany [] [] = return M.empty
unifyMany (t1 : ts1) (t2 : ts2) =
  do su1 <- unify t1 t2
     su2 <- unifyMany (apply su1 ts1) (apply su1 ts2)
     return (su2 `compose` su1)
unifyMany t1 t2 = throwError $ "Type mismatch " ++ show (head t1) ++ " ~ " ++ show (head t2)

bind :: TVar -> Type -> Solve Substitution
bind v t
    | v `S.member` tvs t = throwError $ "Infinite type " ++ show v ++ " ~ " ++ show t
    | otherwise = return $ M.singleton v t 

solve :: Substitution -> [Constraint] -> Solve Substitution
solve s c =
    case c of
        [] -> return s
        (CEqual t1 t2 : cs) -> do
            s1 <- unify t1 t2
            let nsub = s1 `compose` s
            solve (s1 `compose` s) (apply s1 cs)

runSolve :: [Constraint] -> Either String Substitution
runSolve cs = runIdentity $ runExceptT $ solve M.empty cs

-- Utility
searchReturnsDecl :: TypedDecl -> Infer [Type]
searchReturnsDecl (DStmt (SRet expr)) = return [typeOfExpr expr]
searchReturnsDecl _ = return []

searchReturnsExpr :: TypedExpr -> Infer [Type]
searchReturnsExpr (EBlock _ decls _) = do
    res <- traverse searchReturnsDecl decls
    return (concat res)
searchReturnsExpr _ = return []
