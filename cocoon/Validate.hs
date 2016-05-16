{-# LANGUAGE RecordWildCards, FlexibleContexts #-}

module Validate ( validate
                , validateConfig) where

import Control.Monad.Except
import qualified Data.Graph.Inductive as G
import Data.Maybe
import Data.List

import Syntax
import NS
import Util
import Type
import Pos
import Name
import Expr
import Refine
import Statement

-- Validate spec.  Constructs a series of contexts, sequentially applying 
-- refinements from the spec, and validates each context separately.
validate :: (MonadError String me) => Spec -> me [Refine]
validate (Spec []) = err nopos "Empty spec"
validate (Spec (r:rs)) = do
    combined <- liftM reverse $ foldM (\(p:rs') new -> liftM (:p:rs') (combine p new)) [r] rs
    mapM_ validate1 combined
    validateFinal $ last combined
    return combined

-- Validate configuration applied on top of a base spec
validateConfig :: (MonadError String me) => Refine -> [Function] -> me Refine
validateConfig base cfg = do
    combined <- combine base (Refine nopos [] [] cfg [] [] [])
    validate1 combined
    -- All functions are defined
    mapM_ (\f -> assertR combined (isJust $ funcDef f) (pos f) $ "Function " ++ name f ++ " is undefined") $ refineFuncs combined
    return combined

-- Validate final refinement before generating topology from it
validateFinal :: (MonadError String me) => Refine -> me ()
validateFinal r = do
    mapM_ (\Role{..} -> mapM_ (\f -> assertR r (isJust $ funcDef $ getFunc r f) (pos roleKeyRange) $ "Key range expression depends on undefined function " ++ f) 
                        $ exprFuncsRec r roleKeyRange)
          $ refineRoles r
    case grCycle (funcGraph r) of
         Nothing -> return ()
         Just t  -> err (pos $ getFunc r $ snd $ head t) $ "Recursive function definition: " ++ (intercalate "->" $ map (name . snd) t)
    mapM_ (roleValidateFinal r) $ refineRoles r
    mapM_ (nodeValidateFinal r) $ refineNodes r
--    mapM_ (\rl -> (mapM_ (\f -> assertR r (isJust $ funcDef $ getFunc r f) (pos rl) $ "Output port behavior depends on undefined function " ++ f)) 
--                  $ statFuncsRec r $ roleBody rl)
--          $ concatMap (map (getRole r . snd) . nodePorts) 
--          $ refineNodes r

-- Apply definitions in new on top of prev.
combine :: (MonadError String me) => Refine -> Refine -> me Refine
combine prev new = do 
    prev' <- foldM (\r role -> do assertR r (isJust $ find ((==role) . roleName) (refineRoles r)) (pos new) 
                                          $ "Role " ++ role ++ " is undefined in this context"
                                  assertR r (isJust $ find ((==role) . roleName) (refineRoles new)) (pos new) 
                                          $ "Role " ++ role ++ " is not re-defined by the refinement"
                                  assertR r ((roleKeyRange $ getRole prev role) == (roleKeyRange $ getRole new role)) (pos new) 
                                          $ "Role " ++ role ++ " is re-defined with a different key range"
                                  assertR r ((rolePktGuard $ getRole prev role) == (rolePktGuard $ getRole new role)) (pos new) 
                                          $ "Role " ++ role ++ " is re-defined with a different guard"
                                  return r{refineRoles = filter ((/=role) . roleName) $ refineRoles r}) prev (refineTarget new)
    let types   = refineTypes prev'   ++ refineTypes new
        roles   = refineRoles prev'   ++ refineRoles new
        assumes = refineAssumes prev' ++ refineAssumes new 
        nodes   = refineNodes prev'   ++ refineNodes new 
    funcs <- mergeFuncs $ refineFuncs prev'  ++ refineFuncs new
    return $ Refine (pos new) (refineTarget new) types funcs roles assumes nodes

mergeFuncs :: (MonadError String me) => [Function] -> me [Function]
mergeFuncs []     = return []
mergeFuncs (f:fs) = do
    case find ((== name f) . name) fs of
         Nothing -> liftM (f:) $ mergeFuncs fs
         Just f' -> do checkFRefinement f f'
                       mergeFuncs fs

-- check that f' has the same signature and domain as f, and f does not have a body
checkFRefinement :: (MonadError String me) => Function -> Function -> me ()
checkFRefinement f f' = do
    assert (funcArgs f == funcArgs f') (pos f') $ "Arguments of " ++ name f' ++ " do not match previous definition at " ++ spos f
    assert (funcType f == funcType f') (pos f') $ "Type of " ++ name f' ++ " do not match previous definition at " ++ spos f
    assert (isNothing $ funcDef f) (pos f') $ "Cannot re-define function " ++ name f' ++ " previously defined at " ++ spos f

-- construct dependency graph
typeGraph :: Refine -> G.Gr TypeDef ()
typeGraph _ = undefined

-- Validate refinement with previous definitions inlined
validate1 :: (MonadError String me) => Refine -> me ()
validate1 r@Refine{..} = do
    uniqNames (\n -> "Multiple definitions of role " ++ n) refineRoles
    uniqNames (\n -> "Multiple definitions of type " ++ n) refineTypes
    assertR r (isJust $ find ((==packetTypeName) . tdefName) refineTypes) (pos r) $ packetTypeName ++ " is undefined"
    uniqNames (\n -> "Multiple definitions of function " ++ n) refineFuncs
    uniqNames (\n -> "Multiple definitions of node " ++ n) refineNodes
    mapM_ (typeValidate r . tdefType) refineTypes
    -- each role occurs at most once as a port
    uniq' (\_ -> (pos r)) id (++ " is mentioned twice as a port") $ concatMap (concatMap (\(i,o) -> [i,o]) . nodePorts) refineNodes
    -- TODO: check for cycles in the types graph - catch recursive type definitions
--    case grCycle (typeGraph r) of
--         Nothing -> return ()
--         Just t  -> err (pos $ snd $ head t) $ "Recursive type definition: " ++ (intercalate "->" $ map (name . snd) t)

    mapM_ (funcValidate r) refineFuncs
    mapM_ (roleValidate r) refineRoles
    mapM_ (assumeValidate r) refineAssumes
    -- TODO: check for cycles in the locations graph
    mapM_ (nodeValidate r) refineNodes

typeValidate :: (MonadError String me) => Refine -> Type -> me ()
typeValidate _ (TUInt p w)    = assert (w>0) p "Integer width must be greater than 0"
typeValidate r (TStruct _ fs) = do uniqNames (\f -> "Multiple definitions of field " ++ f) fs
                                   mapM_ (typeValidate r . fieldType) fs
typeValidate r (TUser   p n)  = do _ <- checkType p r n
                                   return ()
typeValidate _ _              = return ()

funcValidate :: (MonadError String me) => Refine -> Function -> me ()
funcValidate r f@Function{..} = do
    uniqNames (\a -> "Multiple definitions of argument " ++ a) funcArgs
    mapM_ (typeValidate r . fieldType) funcArgs
    typeValidate r funcType
    exprValidate r (CtxFunc f) funcDom
    case funcDef of
         Nothing  -> return ()
         Just def -> do exprValidate r (CtxFunc f) def
                        matchType r (CtxFunc f) funcType def 

roleValidate :: (MonadError String me) => Refine -> Role -> me ()
roleValidate r role@Role{..} = do
    uniqNames (\k -> "Multiple definitions of key " ++ k) roleKeys
    mapM_ (typeValidate r . fieldType) roleKeys
    exprValidate r (CtxRole role) roleKeyRange
    exprValidate r (CtxRole role) rolePktGuard
    _ <- statValidate r role [] roleBody
    return ()

roleValidateFinal :: (MonadError String me) => Refine -> Role -> me ()
roleValidateFinal _ Role{..} = do
    assert (statIsDeterministic roleBody) (pos roleBody) "Cannot synthesize non-deterministic behavior"
    return ()

assumeValidate :: (MonadError String me) => Refine -> Assume -> me ()
assumeValidate r a@Assume{..} = do
    uniqNames (\v -> "Multiple definitions of variable " ++ v) assVars
    mapM_ (typeValidate r . fieldType) assVars
    exprValidate r (CtxAssume a) assExpr
    assertR r (isBool r (CtxAssume a) assExpr) (pos assExpr) $ "Not a boolean expression"
    return ()

nodeValidate :: (MonadError String me) => Refine -> Node -> me ()
nodeValidate r nd@Node{..} = do
    nodeRole <- checkRole (pos nd) r nodeName
    -- for each port 
    mapM_ (\(p1,p2) -> do r1 <- checkRole (pos nd) r p1
                          r2 <- checkRole (pos nd) r p2
                          assertR r (roleKeys r1 == roleKeys r2) (pos nd) 
                                  $ "Input-output roles (" ++ p1 ++ "," ++ p2 ++ ") must have identical parameter lists"
                          assertR r (roleKeyRange r1 == roleKeyRange r2) (pos nd)
                                  $ "Input-output roles (" ++ p1 ++ "," ++ p2 ++ ") must have identical key ranges"
                          let validateR rl = do assertR r (length (roleKeys rl) > 0 && isUInt r (CtxRole rl) (last $ roleKeys rl)) (pos nd) 
                                                        $ "Port " ++ name rl ++ " must be indexed with an integer key"
                                                assertR r ((init $ roleKeys rl) == roleKeys nodeRole) (pos nd) 
                                                       $ "Port " ++ name rl ++ " must be indexed with the same keys as node " ++ nodeName ++ " and one extra integer key" 
                          validateR r1
                          validateR r2)
          nodePorts

nodeValidateFinal :: (MonadError String me) => Refine -> Node -> me ()
nodeValidateFinal r nd@Node{..} = do
    -- for each port 
    mapM_ (\(p1,p2) -> do r1 <- checkRole (pos nd) r p1
                          r2 <- checkRole (pos nd) r p2
                          -- input ports can only send to output ports of the same node
                          assertR r (all (\(ELocation _ rl args) -> (elem rl (map snd nodePorts)) && 
                                                                    (all (\(key, arg) -> arg == (EVar nopos $ name key)) $ zip (init $ roleKeys r1) args)) 
                                         $ statSendsTo (roleBody r1)) (pos nd)
                                 $ "Inbound port " ++ p1 ++ " is only allowed to forward packets to the node's outbound ports"
                          assertR r (not $ any (\(ELocation _ rl _) -> elem rl (map snd nodePorts)) $ statSendsTo (roleBody r2)) (pos nd)
                                 $ "Outbound port " ++ p2 ++ " is not allowed to forward packets to other outbound ports"
                          checkLinkSt $ roleBody r2)
          nodePorts



checkLinkSt :: (MonadError String me) => Statement -> me ()
checkLinkSt (SSeq _ s1 s2)  = do checkLinkSt s1
                                 checkLinkSt s2
checkLinkSt (SPar p _  _)   = err p "Parallel composition not allowed in output port body" 
checkLinkSt (SITE _ c t e)  = do checkLinkExpr c
                                 checkLinkSt t
                                 maybe (return ()) checkLinkSt e
checkLinkSt (STest _ e)     = checkLinkExpr e
checkLinkSt (SSet p _ _)    = err p "Output port may not modify packets"
checkLinkSt (SSend _ e)     = checkLinkExpr e
checkLinkSt (SSendND _ _ _) = error "Validate.checkLinkSt SSendND" 
checkLinkSt (SHavoc _ _)    = error "Validate.checkLinkSt SHavoc" 
checkLinkSt (SAssume _ _)   = error "Validate.checkLinkSt SAssume" 

checkLinkExpr :: (MonadError String me) => Expr -> me ()
checkLinkExpr (EVar    _ _)       = return ()
checkLinkExpr (EDotVar    _ _)    = return ()
checkLinkExpr (EPacket p)         = err p "Output port body may not inspect packet headers"
checkLinkExpr (EApply  _ _ as)    = mapM_ checkLinkExpr as
checkLinkExpr (EField _ s _)      = checkLinkExpr s
checkLinkExpr (ELocation _ _ es)  = mapM_ checkLinkExpr es
checkLinkExpr (EBool _ _)         = return ()
checkLinkExpr (EInt _ _ _)        = return ()
checkLinkExpr (EStruct _ _ fs)    = mapM_ checkLinkExpr fs
checkLinkExpr (EBinOp _ _ e1 e2)  = do checkLinkExpr e1
                                       checkLinkExpr e2
checkLinkExpr (EUnOp _ _ e)       = checkLinkExpr e
checkLinkExpr (ESlice _ e _ _)     = checkLinkExpr e
checkLinkExpr (ECond _ cs d)      = do mapM_ (\(c,v) -> do checkLinkExpr c
                                                           checkLinkExpr v) cs
                                       checkLinkExpr d

exprValidate :: (MonadError String me) => Refine -> ECtx -> Expr -> me ()
exprValidate _ ctx (EVar p v) = do 
   _ <- checkVar p ctx v
   return ()
exprValidate r ctx (EDotVar p v) = 
   case ctx of
        CtxSend _ t -> assertR r (isJust $ find ((== v) . name) $ roleKeys t) p $ "Unknown key " ++ v
        _           -> errR r p "Dot-variable is not allowed here"
exprValidate r ctx (EPacket p) = do 
   case ctx of
        CtxAssume _ -> errR r p "Assumptions cannot refer to pkt"
        CtxFunc _   -> errR r p "Functions cannot refer to pkt"
        CtxRole _   -> return ()
        CtxSend _ _ -> return ()
   return ()
exprValidate r ctx (EApply p f as) = do
    func <- checkFunc p r f
    assertR r ((length $ funcArgs func) == length as) p "Number of arguments does not match function declaration"
    mapM_ (\(formal,actual) -> do exprValidate r ctx actual
                                  matchType r ctx actual formal) 
          $ zip (funcArgs func) as
exprValidate r ctx (EField p s f) = do
    exprValidate r ctx s
    case typ' r ctx s of
        TStruct _ fs -> assertR r (isJust $ find ((==f) . fieldName) fs) p $ "Unknown field " ++ f
        _            -> err p $ "Expression is not of struct type"

exprValidate r ctx (ELocation p rname as) = do
    role' <- checkRole p r rname
    assertR r ((length $ roleKeys role') == length as) p "Number of keys does not match role declaration"
    mapM_ (\(formal,actual) -> do exprValidate r ctx actual
                                  matchType r ctx actual formal) 
          $ zip (roleKeys role') as

exprValidate r ctx (EStruct p n as) = do
    t <- checkType p r n
    case typ' r ctx (tdefType t) of
         TStruct _ fs -> do assertR r (length as == length fs) p "Number of fields does not match struct definition"
                            mapM_ (\(field, e) -> do exprValidate r ctx e
                                                     matchType r ctx e field)
                                  $ zip fs as
         _            -> err p $ n ++ " is not a struct type"
exprValidate r ctx (EBinOp _ op left right) = do
    exprValidate r ctx left
    exprValidate r ctx right
    if' (elem op [Eq, Neq]) (matchType r ctx left right)
     $ if' (elem op [Lt, Lte, Gt, Gte, Plus, Minus, ShiftL, ShiftR]) (
          do assertR r (isUInt r ctx left)  (pos left)  $ "Not an integer expression"
             assertR r (isUInt r ctx right) (pos right) $ "Not an integer expression"
             matchType r ctx left right)
     $ if' (elem op [And, Or, Impl]) (
          do assertR r (isBool r ctx left)  (pos left)  $ "Not a boolean expression"
             assertR r (isBool r ctx right) (pos right) $ "Not a boolean expression")
     $ if' (elem op [Mod, Concat]) (
          do assertR r (isUInt r ctx left)  (pos left)  $ "Not an integer expression"
             assertR r (isUInt r ctx right) (pos right) $ "Not an integer expression") 
     $ undefined

exprValidate r ctx (EUnOp _ op e) = do
    exprValidate r ctx e
    case op of
         Not -> assertR r (isBool r ctx e) (pos e)  $ "Not a boolean expression"

exprValidate r ctx (ESlice p e h l) = do
    exprValidate r ctx e
    case typ' r ctx e of
         TUInt _ w -> do assertR r (h >= l) p "Upper bound of the slice must be greater than lower bound"
                         assertR r (h < w) p "Upper bound of the slice cannot exceed argument width"
         _         -> errR r (pos e) "Cannot take slice of a non-integer expression"

exprValidate r ctx (ECond _ cs def) = do
    exprValidate r ctx def
    mapM_ (\(cond, e)-> do exprValidate r ctx cond
                           exprValidate r ctx e
                           assertR r (isBool r ctx cond) (pos cond) $ "Not a boolean expression"
                           matchType r ctx e def) cs

exprValidate _ _ _ = return ()


lexprValidate :: (MonadError String me) => Refine -> ECtx -> [Expr] -> Expr -> me ()
lexprValidate r ctx mset e = do
    exprValidate r ctx e
    assertR r (isLExpr e) (pos e) "Not an l-value"
    checkNotModified r ctx mset e

isLExpr :: Expr -> Bool
isLExpr (EVar _ _)        = False
isLExpr (EDotVar _ _)     = False
isLExpr (EPacket _)       = True
isLExpr (EApply _ _ _)    = False
isLExpr (EField _ s _)    = isLExpr s
isLExpr (ELocation _ _ _) = False
isLExpr (EBool _ _)       = False
isLExpr (EInt _ _ _)      = False
isLExpr (EStruct _ _ _)   = False
isLExpr (EBinOp _ _ _ _)  = False
isLExpr (EUnOp _ _ _)     = False
isLExpr (ESlice _ _ _ _)  = False -- TODO: allow this
isLExpr (ECond _ _ _)     = False

-- Checks that no part of lvalue e is in the modified set mset
checkNotModified :: (MonadError String me) => Refine -> ECtx -> [Expr] -> Expr -> me ()
checkNotModified r ctx mset e = do
    let checkParent e' = do assert (not $ elem e' mset) (pos e') $ show e' ++ " has already been assigned"
                            case e' of
                                 EField _ p _ -> checkParent p
                                 _            -> return ()
    -- e and its ancestors are not in mset
    checkParent e
    -- recursively check children
    case typ' r ctx e of
         TStruct _ fs -> mapM_ (checkNotModified r ctx mset . EField nopos e . name) fs
         _            -> return()


statValidate :: (MonadError String me) => Refine -> Role -> [Expr] -> Statement -> me (Bool, [Expr])
statValidate r role mset (SSeq _ h t) = do
    (sends, mset') <- statValidate r role mset h
    assertR r (not sends) (pos h) "Send not allowed in the middle of a sequence"
    statValidate r role mset' t

statValidate r role mset (SPar _ h t) = do
    (sends1, mset1) <- statValidate r role mset h
    (sends2, mset2) <- statValidate r role mset t
    return $ (sends1 || sends2, union mset1 mset2)

statValidate r role mset (SITE _ c t e) = do
    exprValidate r (CtxRole role) c
    assertR r (isBool r (CtxRole role) c) (pos c) "Condition must be a boolean expression"
    (sends1, mset1) <- statValidate r role mset t
    (sends2, mset2) <- maybe (return (False,[])) (statValidate r role mset) e
    return $ (sends1 || sends2, union mset1 mset2)

statValidate r role mset (STest _ c) = do
    exprValidate r (CtxRole role) c
    assertR r (isBool r (CtxRole role) c) (pos c) "Filter must be a boolean expression"
    return (False, mset)

statValidate r role mset (SSet _ lval rval) = do
    exprValidate r (CtxRole role) rval
    lexprValidate r (CtxRole role) mset lval
    matchType r (CtxRole role) lval rval
    when (exprIsValidFlag lval) $ case rval of
                                       EBool _ _ -> return ()
                                       _         -> errR r (pos rval) $ "Not a boolean constant"
    return (False, union [lval] mset)

statValidate r role mset (SSend _ dst) = do
    exprValidate r (CtxRole role) dst
    assertR r (isLocation r (CtxRole role) dst) (pos dst) "Not a valid location"
    case dst of
         ELocation _ _ _ -> return ()
         _               -> errR r (pos dst)  "send destination must be of the form Role[args]"
    let ELocation p rl _ = dst
    assertR r (rl /= name role) p "role cannot send to itself"
    return (True, mset)

statValidate r role mset (SSendND p rl c) = do
    role' <- checkRole p r rl
    exprValidate r (CtxSend role role') c
    assertR r (isBool r (CtxSend role role') c) (pos c) "Condition must be a boolean expression"
    assertR r (rl /= name role) p "role cannot send to itself"
    return (True, mset)

statValidate r role mset (SHavoc _ lval) = do
    lexprValidate r (CtxRole role) mset lval
    return (False, union [lval] mset)

statValidate r role mset (SAssume _ c) = do
    exprValidate r (CtxRole role) c
    assertR r (isBool r (CtxRole role) c) (pos c) "Assumption must be a boolean expression"
    return (False, mset)