-----------------------------------------------------------------------------
-- Module      :  Parser.y
-- Copyright   :  (c) 2005-2007 Duncan Coutts
--                (c) 2008 Benedikt Huber        
--                (c) [1999..2004] Manuel M T Chakravarty
--                Portions copyright 1989, 1990 James A. Roskind
-- License     :  BSD-style
-- Maintainer  :  benedikt.huber@gmail.com
-- Portability :  portable
--
--  Parser for C translation units, which have already been run through the C
--  preprocessor.  
--
--  The parser recognizes all of ISO C 99 and most GNU C extensions.
--
--  With C99 we refer to the ISO C99 standard, specifically the section numbers
--  used below refer to this report:
--
--    http://www.open-std.org/jtc1/sc22/wg14/www/docs/n1124.pdf
--
--  Relevant sections:
--
-- 6.5 Expressions .1 - .17 and 6.6 (almost literally)
--  Supported GNU extensions:
--     - Allow a compound statement as an expression
--     - Various __builtin_* forms that take type parameters
--     - `alignof' expression or type
--     - `__extension__' to suppress warnings about extensions
--     - Allow taking address of a label with: && label
--     - Omitting the `then' part of conditional expressions
--     - complex numbers
--
-- 6.7 C Declarations .1 -.8
--  Supported GNU extensions:
--     - '__thread' thread local storage (6.7.1)
--
-- 6.8 Statements .1 - .8
--  Supported GNU extensions:
--    - case ranges (C99 6.8.1)
--    - '__label__ ident;' declarations (C99 6.8.2)
--    - computed gotos (C99 6.8.6)
--    
-- 6.9 Translation unit
--  Supported GNU extensions:
--     - allow empty translation_unit
--     - allow redundant ';'
--     - allow extension keyword before external declaration
--     - asm definitions
--
-- GNU extensions are documented in the gcc parser
--    
--    http://gcc.gnu.org/viewcvs/trunk/gcc/c-parser.c
--
-- and on: http://gcc.gnu.org/onlinedocs/gcc/C-Extensions.html
--
------------------------------------------------------------------
{
module Language.C.Parser.Parser (parseC) where

--  Since some of the grammar productions are quite difficult to read,
--  (especially those involved with the decleration syntax) we document them
--  with an extended syntax that allows a more consise representation:
--
--  Ordinary rules
--
--   foo      named terminal or non-terminal
--
--   'c'      terminal, literal character token
--
--   A B      concatenation
--
--   A | B    alternation
--
--   (A)      grouping
--
--  Extended rules
--
--   A?       optional, short hand for (A|) or [A]{ 0==A || 1==A }
--
--   ...      stands for some part of the grammar omitted for clarity
--
--   {A}      represents sequences, 0 or more.
--
--   <permute> modifier which states that any permutation of the immediate subterms is valid
--
--  Comments:
--
--  * Subtrees representing empty declarators of the form `CVarDeclr Nothing
--    at' have *no* valid attribute handle in `at' (only a `newAttrsOnlyPos
--    nopos').
--
--  * Builtin type names are imported from `CBuiltin'.
--
--- TODO ----------------------------------------------------------------------
--
--  !* We ignore the C99 static keyword (see C99 6.7.5.3)
--  !* We do not distinguish in the AST between incomplete array types and
--      complete variable length arrays ([ '*' ] means the latter). (see C99 6.7.5.2)
--  !* The AST doesn't allow recording __attribute__ of unnamed struct field
--
--  * Documentation isn't complete and consistent yet.

import Prelude    hiding (reverse)
import qualified Data.List as List

import Language.C.Toolkit.Position   (Position, Pos(..), nopos)
import Language.C.Toolkit.UNames     (names, namesStartingFrom)
import Language.C.Toolkit.Idents     (Ident, internalIdent)
import Language.C.Toolkit.Attributes (Attrs, newAttrs, newAttrsOnlyPos, attrsOf)

import Language.C.Parser.Lexer     (lexC, parseError)
import Language.C.AST.AST       (CHeader(..), CExtDecl(..), CFunDef(..), CStat(..),
                   CBlockItem(..), CDecl(..), CAttr(..), CDeclSpec(..), CStorageSpec(..),
                   CTypeSpec(..), CTypeQual(..), CStructUnion(..),
                   CStructTag(..), CEnum(..), CDeclr(..), varDeclr, CInit(..), CInitList, CAttr(..), appendDeclrAttrs,
                   CDesignator(..), CExpr(..), CAssignOp(..), CBinaryOp(..),
                   CUnaryOp(..), CConst (..), CStrLit (..), cstrConst, 
                   CAsmStmt(..), CAsmOperand(..), CBuiltin(..))
import Language.C.AST.Builtin   (builtinTypeNames)
import Language.C.Parser.Tokens    (CToken(..), GnuCTok(..))
import Language.C.Toolkit.ParserMonad (P, execParser, getNewName, addTypedef, shadowTypedef,
                     enterScope, leaveScope )
}

%name header header
%tokentype { CToken }

%monad { P } { >>= } { return }
%lexer { lexC } { CTokEof }

%expect 1

%token

'('		{ CTokLParen	_ }
')'		{ CTokRParen	_ }
'['		{ CTokLBracket	_ }
']'		{ CTokRBracket	_ }
"->"		{ CTokArrow	_ }
'.'		{ CTokDot	_ }
'!'		{ CTokExclam	_ }
'~'		{ CTokTilde	_ }
"++"		{ CTokInc	_ }
"--"		{ CTokDec	_ }
'+'		{ CTokPlus	_ }
'-'		{ CTokMinus	_ }
'*'		{ CTokStar	_ }
'/'		{ CTokSlash	_ }
'%'		{ CTokPercent	_ }
'&'		{ CTokAmper	_ }
"<<"		{ CTokShiftL	_ }
">>"		{ CTokShiftR	_ }
'<'		{ CTokLess	_ }
"<="		{ CTokLessEq	_ }
'>'		{ CTokHigh	_ }
">="		{ CTokHighEq	_ }
"=="		{ CTokEqual	_ }
"!="		{ CTokUnequal	_ }
'^'		{ CTokHat	_ }
'|'		{ CTokBar	_ }
"&&"		{ CTokAnd	_ }
"||"		{ CTokOr	_ }
'?'		{ CTokQuest	_ }
':'		{ CTokColon	_ }
'='		{ CTokAssign	_ }
"+="		{ CTokPlusAss	_ }
"-="		{ CTokMinusAss	_ }
"*="		{ CTokStarAss	_ }
"/="		{ CTokSlashAss	_ }
"%="		{ CTokPercAss	_ }
"&="		{ CTokAmpAss	_ }
"^="		{ CTokHatAss	_ }
"|="		{ CTokBarAss	_ }
"<<="		{ CTokSLAss	_ }
">>="		{ CTokSRAss	_ }
','		{ CTokComma	_ }
';'		{ CTokSemic	_ }
'{'		{ CTokLBrace	_ }
'}'		{ CTokRBrace	_ }
"..."		{ CTokEllipsis	_ }
alignof		{ CTokAlignof	_ }
asm		{ CTokAsm	_ }
auto		{ CTokAuto	_ }
break		{ CTokBreak	_ }
"_Bool"		{ CTokBool	_ }
case		{ CTokCase	_ }
char		{ CTokChar	_ }
const		{ CTokConst	_ }
continue	{ CTokContinue	_ }
"_Complex"	{ CTokComplex	_ }
default		{ CTokDefault	_ }
do		{ CTokDo	_ }
double		{ CTokDouble	_ }
else		{ CTokElse	_ }
enum		{ CTokEnum	_ }
extern		{ CTokExtern	_ }
float		{ CTokFloat	_ }
for		{ CTokFor	_ }
goto		{ CTokGoto	_ }
if		{ CTokIf	_ }
inline		{ CTokInline	_ }
int		{ CTokInt	_ }
long		{ CTokLong	_ }
"__label__"	{ CTokLabel	_ }
register	{ CTokRegister	_ }
restrict	{ CTokRestrict	_ }
return		{ CTokReturn	_ }
short		{ CTokShort	_ }
signed		{ CTokSigned	_ }
sizeof		{ CTokSizeof	_ }
static		{ CTokStatic	_ }
struct		{ CTokStruct	_ }
switch		{ CTokSwitch	_ }
typedef		{ CTokTypedef	_ }
typeof		{ CTokTypeof	_ }
"__thread"	{ CTokThread	_ }
union		{ CTokUnion	_ }
unsigned	{ CTokUnsigned	_ }
void		{ CTokVoid	_ }
volatile	{ CTokVolatile	_ }
while		{ CTokWhile	_ }
cchar		{ CTokCLit   _ _ }		-- character constant
cint		{ CTokILit   _ _ }		-- integer constant
cfloat		{ CTokFLit   _ _ }		-- float constant
cstr		{ CTokSLit   _ _ }		-- string constant (no escapes)
ident		{ CTokIdent  _ $$ }		-- identifier
tyident		{ CTokTyIdent _ $$ }		-- `typedef-name' identifier
"__attribute__"	{ CTokGnuC GnuCAttrTok _ }	-- special GNU C tokens
"__extension__"	{ CTokGnuC GnuCExtTok  _ }	-- special GNU C tokens
"__real__"        { CTokGnuC GnuCComplexReal _ } 
"__imag__"        { CTokGnuC GnuCComplexImag _ } 
-- special GNU C builtin 'functions' that actually take types as parameters:
"__builtin_va_arg"		{ CTokGnuC GnuCVaArg    _ }
"__builtin_offsetof"		{ CTokGnuC GnuCOffsetof _ }
"__builtin_types_compatible_p"	{ CTokGnuC GnuCTyCompat _ }

%%


-- parse a complete C header file
--
header :: { CHeader }
header
  : translation_unit	{% withAttrs $1 $ CHeader (reverse $1) }


-- parse a complete C translation unit (C99 6.9)
--
-- * GNU extensions:
--     allow empty translation_unit
--     allow redundant ';'
--
translation_unit :: { Reversed [CExtDecl] }
translation_unit
  : {- empty -}					{ empty }
  | translation_unit ';'			{ $1 }
  | translation_unit external_declaration	{ $1 `snoc` $2 }


-- parse external C declaration (C99 6.9)
--
-- * GNU extensions:
--     allow extension keyword before external declaration
--     asm definitions
external_declaration :: { CExtDecl }
external_declaration
  : function_definition		              { CFDefExt $1 }
  | declaration			                  { CDeclExt $1 }
  | "__extension__" external_declaration  { $2 }
  | asm '(' string_literal ')' ';'		  {% withAttrs $2 $ CAsmExt $3 }


-- parse C function definition (C99 6.9.1)
--
-- function_definition :- specifiers? fun-declarator compound-statement
--                        specifiers? old-fun-declarator  declaration-list compound-statement
--
-- The specifiers are a list consisting of type-names (int, struct foo, ...),
-- storage-class specifiers (extern, static,...) and type qualifiers (const, volatile, ...).
--
--   declaration_specifier      :- <permute> type-qualifier* storage-class+ typename+    "extern unsigned static volatile int f()"
--   type_specifier             :- <permute> type-qualifier* typename+                   "const int f()", "long int f()"
--   declaration_qualifier_list :- <permute> type_qualifier* storage-class+              "extern static const f()"
--   type_qualifier_list        :- type-qualifier+                                       "const f()"
--
-- * GNU extension: 
--    __attribute__ annotations
--
function_definition :: { CFunDef }
function_definition
  :                            function_declarator compound_statement
  	{% leaveScope >> (withAttrs $1 $ CFunDef [] $1 [] $2) }

  |                      attrs function_declarator compound_statement
    {% leaveScope >> (withAttrs $2 $ CFunDef (liftCAttrs $1) $2 [] $3) }

  | declaration_specifier      function_declarator compound_statement
	  {% leaveScope >> (withAttrs $1 $ CFunDef $1 $2 [] $3) }

  | type_specifier             function_declarator compound_statement
	  {% leaveScope >> (withAttrs $1 $ CFunDef $1 $2 [] $3) }

  | declaration_qualifier_list function_declarator compound_statement
	  {% leaveScope >> (withAttrs $1 $ CFunDef (reverse $1) $2 [] $3) }

  | type_qualifier_list   function_declarator compound_statement 
	  {% leaveScope >> (withAttrs $1 $ CFunDef (liftTypeQuals $1) $2 [] $3) }

  | type_qualifier_list   attrs function_declarator compound_statement
	  {% leaveScope >> (withAttrs $1 $ CFunDef (liftTypeQuals $1 ++ liftCAttrs $2) $3 [] $4) }
  
  -- old function declarators

  |                            old_function_declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef [] $1 (reverse $2) $3 }

  |                      attrs old_function_declarator declaration_list compound_statement
  	{% withAttrs $2 $ CFunDef (liftCAttrs $1) $2 (reverse $3) $4 }

  | declaration_specifier      old_function_declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef $1 $2 (reverse $3) $4 }

  | type_specifier             old_function_declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef $1 $2 (reverse $3) $4 }

  | declaration_qualifier_list old_function_declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef (reverse $1) $2 (reverse $3) $4 }

  | type_qualifier_list   old_function_declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef (liftTypeQuals $1) $2 (reverse $3) $4 }

  | type_qualifier_list attrs  old_function_declarator declaration_list compound_statement
  	{% withAttrs $1 $ CFunDef (liftTypeQuals $1  ++ liftCAttrs $2) $3 (reverse $4) $5 }

-- Read declarator and put function
function_declarator :: { CDeclr }
function_declarator
  : identifier_declarator
  	{% enterScope >> doFuncParamDeclIdent $1 >> return $1 }


-- parse C statement (C99 6.8)
--
-- * GNU extension: ' __asm__ (...); ' statements
--
statement :: { CStat }
statement
  : labeled_statement			{ $1 }
  | compound_statement		{ $1 }
  | expression_statement	{ $1 }
  | selection_statement		{ $1 }
  | iteration_statement		{ $1 }
  | jump_statement			  { $1 }
  | asm_statement			    {% withAttrs $1 (CAsm $1) }


-- parse C labeled statement (C99 6.8.1)
--
-- * GNU extension: case ranges
--
labeled_statement :: { CStat }
labeled_statement
  : identifier ':' attrs_opt statement		{% withAttrs $2 $ CLabel $1 $4 $3 }
  | case constant_expression ':' statement	{% withAttrs $1 $ CCase $2 $4 }
  | default ':' statement			{% withAttrs $1 $ CDefault $3 }
  | case constant_expression "..." constant_expression ':' statement
  	{% withAttrs $1 $ CCases $2 $4 $6 }


-- parse C compound statement (C99 6.8.2)
--
-- * GNU extension: '__label__ ident;' declarations
--
compound_statement :: { CStat }
compound_statement
  : '{' enter_scope block_item_list leave_scope '}'
  	{% withAttrs $1 $ CCompound [] (reverse $3) }

  | '{' enter_scope label_declarations block_item_list leave_scope '}'
  	{% withAttrs $1 $ CCompound (reverse $3) (reverse $4) }


-- No syntax for these, just side effecting semantic actions.
--
enter_scope :: { () }
enter_scope : {% enterScope }
leave_scope :: { () }
leave_scope : {% leaveScope }


block_item_list :: { Reversed [CBlockItem] }
block_item_list
  : {- empty -}			{ empty }
  | block_item_list block_item	{ $1 `snoc` $2 }

block_item :: { CBlockItem }
block_item
  : statement			{ CBlockStmt $1 }
  | nested_declaration		{ $1 }

nested_declaration :: { CBlockItem }
nested_declaration
  : declaration				{ CBlockDecl $1 }
  | nested_function_definition		{ CNestedFunDef $1 }
  | "__extension__" nested_declaration	{ $2 }

nested_function_definition :: { CFunDef }
nested_function_definition
  : declaration_specifier      function_declarator compound_statement
	{% leaveScope >> (withAttrs $1 $ CFunDef $1 $2 [] $3) }

  | type_specifier             function_declarator compound_statement
	{% leaveScope >> (withAttrs $1 $ CFunDef $1 $2 [] $3) }

  | declaration_qualifier_list function_declarator compound_statement
	{% leaveScope >> (withAttrs $1 $ CFunDef (reverse $1) $2 [] $3) }

  | type_qualifier_list   function_declarator compound_statement
	{% leaveScope >> (withAttrs $1 $ CFunDef (liftTypeQuals $1) $2 [] $3) }

  | type_qualifier_list   attrs function_declarator compound_statement
	{% leaveScope >> (withAttrs $1 $ CFunDef (liftTypeQuals $1 ++ liftCAttrs $2) $3 [] $4) }


label_declarations :: { Reversed [Ident] }  
label_declarations
  : "__label__" identifier_list ';'			{ $2 }
  | label_declarations "__label__" identifier_list ';'	{ $1 `rappendr` $3 }


-- parse C expression statement (C99 6.8.3)
--
expression_statement :: { CStat }
expression_statement
  : ';'				{% withAttrs $1 $ CExpr Nothing }
  | expression ';'		{% withAttrs $1 $ CExpr (Just $1) }


-- parse C selection statement (C99 6.8.4)
--
selection_statement :: { CStat }
selection_statement
  : if '(' expression ')' statement
	{% withAttrs $1 $ CIf $3 $5 Nothing }

  | if '(' expression ')' statement else statement
	{% withAttrs $1 $ CIf $3 $5 (Just $7) }

  | switch '(' expression ')' statement	
	{% withAttrs $1 $ CSwitch $3 $5 }


-- parse C iteration statement (C99 6.8.5)
--
iteration_statement :: { CStat }
iteration_statement
  : while '(' expression ')' statement
  	{% withAttrs $1 $ CWhile $3 $5 False }

  | do statement while '(' expression ')' ';'
  	{% withAttrs $1 $ CWhile $5 $2 True }

  | for '(' expression_opt ';' expression_opt ';' expression_opt ')' statement
	{% withAttrs $1 $ CFor (Left $3) $5 $7 $9 }

  | for '(' enter_scope declaration expression_opt ';' expression_opt ')' statement leave_scope
	{% withAttrs $1 $ CFor (Right $4) $5 $7 $9 }


-- parse C jump statement (C99 6.8.6)
--
-- * GNU extension: computed gotos
--
jump_statement :: { CStat }
jump_statement
  : goto identifier ';'			{% withAttrs $1 $ CGoto $2 }
  | goto '*' expression ';'		{% withAttrs $1 $ CGotoPtr $3 }
  | continue ';'			{% withAttrs $1 $ CCont }
  | break ';'				{% withAttrs $1 $ CBreak }
  | return expression_opt ';'		{% withAttrs $1 $ CReturn $2 }


-- parse GNU C __asm__ statement (compatible with C99: J.5.10)
--
-- asm_stmt    :- asm volatile? ( "asm..." : output-operands : input-operands : asm-clobbers )
-- asm_operand :- [operand-name] "constraint" ( expr )  
-- asm_clobber :- "r1", "r2", ...
--              
asm_statement :: { CAsmStmt }
asm_statement
  : asm maybe_type_qualifier '(' string_literal ')' ';'
  	{% withAttrs $1 $ CAsmStmt $2 $4 [] [] [] }

  | asm maybe_type_qualifier '(' string_literal ':' asm_operands ')' ';'
  	{% withAttrs $1 $ CAsmStmt $2 $4 $6 [] [] }

  | asm maybe_type_qualifier '(' string_literal ':' asm_operands ':' asm_operands ')' ';'
  	{% withAttrs $1 $ CAsmStmt $2 $4 $6 $8 [] }

  | asm maybe_type_qualifier '(' string_literal ':' asm_operands ':' asm_operands ':' asm_clobbers ')' ';'
  	{% withAttrs $1 $ CAsmStmt $2 $4 $6 $8 (reverse $10) }


maybe_type_qualifier :: { Maybe CTypeQual }
maybe_type_qualifier
  : {- empty -}		  { Nothing }
  | type_qualifier	{ Just $1 }

asm_operands :: { [CAsmOperand] }
asm_operands
  : {- empty -}				{ [] }
  | nonnull_asm_operands		{ reverse $1 }

nonnull_asm_operands :: { Reversed [CAsmOperand] }
nonnull_asm_operands
  : asm_operand					{ singleton $1 }
  | nonnull_asm_operands ',' asm_operand	{ $1 `snoc` $3 }

asm_operand :: { CAsmOperand }
asm_operand
  : string_literal '(' expression ')'			            {% withAttrs $1 $ CAsmOperand Nothing $1 $3 }
  | '[' ident ']' string_literal '(' expression ')'   {% withAttrs $4 $ CAsmOperand (Just $2) $4 $6 }
  | '[' tyident ']' string_literal '(' expression ')'	{% withAttrs $4 $ CAsmOperand (Just $2) $4 $6 }


asm_clobbers :: { Reversed [CStrLit] }
asm_clobbers
  : string_literal			            { singleton $1 }
  | asm_clobbers ',' string_literal	{ $1 `snoc` $3 }

{-
---------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------
-- Declarations
---------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------

Declarations are the most complicated part of the grammar, and shall be summarized here.
To allow a lightweight notation, we will use the modifier <permute> to indicate that the order of the immidieate right-hand 
sides doesn't matter.
 - <permute> a* b+ c   === any sequence of a's, b's and c's, which contains exactly 1 'c' and at least one 'b'

-- storage class and type qualifier
---------------------------------------------------------------------------------------------------------------
attr                       :-   __attribute__((..))
storage_class              :-   typedef | extern | static | auto | register | __thread
type_qualifier             :-   const | volatile | restrict | inline
type_qualifier_list        :-   type_qualifier+

declaration_qualifier      :-   storage_class | type_qualifier
declaration_qualifier_list :-   <permute> type_qualifier* storage_class+

qualifiers                 :-   declaration_qualifier_list | type_qualifier_list
                           :=   <permute> (type_qualifier|storage_class)+ 

-- type names
---------------------------------------------------------------------------------------------------------------
declaration_specifier      :- <permute> type_qualifier* storage_class+ (basic_type_name+ | elaborated_type_name | tyident )
type_specifier             :- <permute> type_qualifier* (basic_type_name+ | elaborated_type_name | tyident)

specifiers                 :- declaration_specifier | type_specifier
                           := <permute> type_qualifier* storage_class* (basic_type_name+ | elaborated_type_name | tyident ) 

-- struct/union/enum declarations
---------------------------------------------------------------------------------------------------------------
sue_declaration_specifier :- <permute> type_qualifier* storage_class+ elaborated_type_name
sue_type_specifier        :- <permute> type_qualifier* elaborated_type_name

sue_declaration           := sue_declaration_specifier | sue_type_specifier
                          :- <permute> type_qualifier* storage_class* elaborated_type_name

-- declarators
---------------------------------------------------------------------------------------------------------------
identifier_declarator :- ( '*' (type_qualifier | attr)* ) * ident     [ array_decl | "(" parameter-list ")" ]
                               plus additional parenthesis' ending ^^ here
typedef_declartor     :- 
declarator            :- identifier_declarator | typedef_declarator

-- Declaration lists
---------------------------------------------------------------------------------------------------------------
default_declaring_list :- qualifiers ( identifier_declarator asm*attrs* initializer? )_comma_list 

declaring_list         :- specifiers ( declarator asm*attrs* initializer? )_comma_list

declaration_list := default_declaring_list | declaring_list

-- Declaration
---------------------------------------------------------------------------------------------------------------
declaration = sue_declaration | declaration_list

---------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------
-- Attributes
-- (citing http://gcc.gnu.org/onlinedocs/gcc/Attribute-Syntax.html)
---------------------------------------------------------------------------------------------------------------
---------------------------------------------------------------------------------------------------------------

"Attributes may appear after the colon following a label (expect case and default)"

labeled_statement :- identifier ':' attrs_opt statement

"Attributes may go either immediately after the struct/union/enum keyword or after the closing brace"

struct attrs_opt ...
struct ... { } attrs_opt

"In general: Attributes appear as part of declarations, either belonging to a declaration or declarator"

"Any list of specifiers and qualifiers at the start of a declaration may contain attribute specifiers"
"An attribute list may appear immediately before the comma, = or semicolon terminating a declaration of an identifier"

---------------------------------------------------------------------------------------------------------------
For the parser, we modified the following rules to be interleaved with attributes:

default_declaring_list' :-  (declaration_qualifier_list' | type_qualifier_list' attr*) 
                                             identifier_declarator asm*attr* initializer? 
                                 { ',' attr* identifier_declarator asm*attr* initializer? } 
declaring_list' :-          specifier' declarator asm*attr* initializer? 
                                 { ',' attr* declarator asm*attr* initializer? } 


type_qualifier_list' is like type_qualifier_list, but with preceeding and/or interleaving (but not terminating) __attribute__ annotations.
declaration_qualifier_list', declaration_specifier' and type_specifier' are like their unprimed variants, but with arbitrary preceeding, interleaving and/or terminating __attribute__ annotations.

"An attribute list may appear immediately before a declarator other than the first in a comma seperated list of declarators"

"The attribute specifiers may be the only specifiers present (implicit int)" [not supported]

"Attribute specifiers may be mixed with type qualifiers appearing inside the [] of an parameter array declarator" 

tbc.
-}



-- parse C declaration (C99 6.7)
declaration :: { CDecl }
declaration
  : sue_declaration_specifier ';'
  	{% withAttrs $1 $ CDecl (reverse $1) [] }

  | sue_type_specifier ';'
  	{% withAttrs $1 $ CDecl (reverse $1) [] }

  | declaring_list ';'
  	{ case $1 of
            CDecl declspecs dies at ->
              CDecl declspecs (List.reverse dies) at }

  | default_declaring_list ';'
  	{ case $1 of
            CDecl declspecs dies at ->
              CDecl declspecs (List.reverse dies) at }


declaration_list :: { Reversed [CDecl] }
declaration_list
  : {- empty -}					{ empty }
  | declaration_list declaration		{ $1 `snoc` $2 }


-- Note that if a typedef were redeclared, then a declaration
-- specifier must be supplied
--
-- Can't redeclare typedef names
--
-- * SUMMARY: default_declaring_list :- qualifier* identifier_declarator asm_attrs initializer?
--                                                 { ',' identifier_declarator asm_attrs initializer? }
--
-- * GNU extensions
--   __attribute__ annotations imm. before an declarator (see Attribute Syntax, paragraph 11)
--   asm + __attribute__ annotations (end of declarations, see Attribute Syntax, paragraph 12)
--   The assembler annotation is used to specifiy an assembler name for the declarator.
--
default_declaring_list :: { CDecl }
default_declaring_list
  : declaration_qualifier_list identifier_declarator asm_attrs_opt {-{}-} initializer_opt
  	{% let declspecs = reverse $1 in
  	   let declr = addTLDeclrAttrs $3 $2 in
           doDeclIdent declspecs declr
        >> (withAttrs $1 $ CDecl declspecs [(Just declr, $4, Nothing)]) }

  | type_qualifier_list identifier_declarator asm_attrs_opt {-{}-} initializer_opt
  	{% let declspecs = liftTypeQuals $1 in
  	   let declr = addTLDeclrAttrs $3 $2 in
           doDeclIdent declspecs declr
        >> (withAttrs $1 $ CDecl declspecs [(Just declr, $4, Nothing)]) }

  | type_qualifier_list attrs identifier_declarator asm_attrs_opt {-{}-} initializer_opt -- FIX 1600
  	{% let declspecs = liftTypeQuals $1 in
  	   let declr = addTLDeclrAttrs $4 $3 in
           doDeclIdent declspecs declr
        >> (withAttrs $1 $ CDecl (declspecs ++ liftCAttrs $2) [(Just declr, $5, Nothing)]) }

  -- GNU extension: __attribute__ as the only qualifier
  | attrs identifier_declarator asm_attrs_opt {-{}-} initializer_opt
    {% let declspecs = liftCAttrs $1 in
       let declr = addTLDeclrAttrs $3 $2 in
       doDeclIdent declspecs declr 
       >> (withAttrs $1 $ CDecl declspecs [(Just declr, $4, Nothing)]) }

  | default_declaring_list ',' attrs_opt identifier_declarator asm_attrs_opt {-{}-} initializer_opt
  	{% case $1 of
             CDecl declspecs dies at -> do
               let declr = addTLDeclrAttrs (fst $5, snd $5 ++ $3) $4
               doDeclIdent declspecs declr
               return (CDecl declspecs ((Just declr, $6, Nothing) : dies) at) }

-- assembler, followed by attribute annotation
asm_attrs_opt :: { (Maybe CStrLit, [CAttr]) }
asm_attrs_opt 
  : asm_opt attrs_opt 
  { ($1,$2) }

--
-- SUMMARY: declaring_list :- specifier* declarator asm_attrs initializer?
--                                 { ',' declarator asm_attrs initializer? }
--
-- GNU extensions:
--      __attribute__ annotations imm. before an declarator (see Attribute Syntax, paragraph 11)
--      asm + __attribute__ annotations (end of declarations, see Attribute Syntax, paragraph 12)
--      
-- FIXME: record attributes
--
declaring_list :: { CDecl }
declaring_list
  : declaration_specifier declarator asm_attrs_opt initializer_opt
  	{% let declr = addTLDeclrAttrs $3 $2 in
  	   doDeclIdent $1 declr
        >> (withAttrs $1 $ CDecl $1 [(Just declr, $4, Nothing)]) }

  | type_specifier declarator asm_attrs_opt initializer_opt
  	{% let declr = addTLDeclrAttrs $3 $2 in
  	   doDeclIdent $1 declr
        >> (withAttrs $1 $ CDecl $1 [(Just declr, $4, Nothing)]) }

  | declaring_list ',' attrs_opt declarator asm_attrs_opt initializer_opt
  	{% case $1 of
             CDecl declspecs dies at -> do
               let declr = addTLDeclrAttrs (fst $5, snd $5 ++ $3) $4
               doDeclIdent declspecs declr
               return (CDecl declspecs ((Just declr, $6, Nothing) : dies) at) }


-- parse C declaration specifiers (C99 6.7)
--
-- * <permute> type_qualifier* storage_class+ (basic_type_name+ | elaborated_type_name | tyident )
--
declaration_specifier :: { [CDeclSpec] }
declaration_specifier
  : basic_declaration_specifier		{ reverse $1 }	-- Arithmetic or void
  | sue_declaration_specifier		{ reverse $1 }	  -- Struct/Union/Enum
  | typedef_declaration_specifier	{ reverse $1 }	-- Typedef


-- A mixture of type qualifiers (const, volatile, restrict, inline) and storage class specifiers
-- (extern, static, auto, register, __thread), in any order, but containing at least one storage class specifier.
--
-- declaration_qualifier_list :- <permute> type_qualifier* storage_class+
--
-- GNU extensions
--   * arbitrary interleaved __attribute__ annotations
--
declaration_qualifier_list :: { Reversed [CDeclSpec] }
declaration_qualifier_list
  : storage_class
  	{ singleton (CStorageSpec $1) }

  | attrs storage_class
  	{ reverseList (liftCAttrs $1) `snoc` (CStorageSpec $2) } 

  | type_qualifier_list storage_class
  	{ rmap CTypeQual $1 `snoc` CStorageSpec $2 }

  | type_qualifier_list attrs storage_class
  	{ (rmap CTypeQual $1 `rappend` liftCAttrs $2) `snoc` CStorageSpec $3 }

  | declaration_qualifier_list declaration_qualifier
  	{ $1 `snoc` $2 }

  | declaration_qualifier_list attr
  	{ $1 `rappend` (liftCAttrs $2) }

-- 
-- declaration_qualifier :- storage_class | type_qualifier
--
declaration_qualifier :: { CDeclSpec }
declaration_qualifier
  : storage_class		{ CStorageSpec $1 }
  | type_qualifier		{ CTypeQual $1 }     -- const or volatile


-- parse C storage class specifier (C99 6.7.1)
--
-- * GNU extensions: '__thread' thread local storage
--
storage_class :: { CStorageSpec }
storage_class
  : typedef			{% withAttrs $1 $ CTypedef }
  | extern			{% withAttrs $1 $ CExtern }
  | static			{% withAttrs $1 $ CStatic }
  | auto			{% withAttrs $1 $ CAuto }
  | register			{% withAttrs $1 $ CRegister }
  | "__thread"			{% withAttrs $1 $ CThread }


-- parse C type specifier (C99 6.7.2)
--
-- This recignises a whole list of type specifiers rather than just one
-- as in the C99 grammar.
--
-- type_specifier :- <permute> type_qualifier* (basic_type_name+ | elaborated_type_name | tyident)
--
type_specifier :: { [CDeclSpec] }
type_specifier
  : basic_type_specifier		{ reverse $1 }	-- Arithmetic or void
  | sue_type_specifier			{ reverse $1 }	-- Struct/Union/Enum
  | typedef_type_specifier		{ reverse $1 }	-- Typedef

basic_type_name :: { CTypeSpec }
basic_type_name
  : void			{% withAttrs $1 $ CVoidType }
  | char			{% withAttrs $1 $ CCharType }
  | short			{% withAttrs $1 $ CShortType }
  | int				{% withAttrs $1 $ CIntType }
  | long			{% withAttrs $1 $ CLongType }
  | float			{% withAttrs $1 $ CFloatType }
  | double			{% withAttrs $1 $ CDoubleType }
  | signed			{% withAttrs $1 $ CSignedType }
  | unsigned			{% withAttrs $1 $ CUnsigType }
  | "_Bool"			{% withAttrs $1 $ CBoolType }
  | "_Complex"			{% withAttrs $1 $ CComplexType }


-- A mixture of type qualifiers, storage class and basic type names in any
-- order, but containing at least one basic type name and at least one storage
-- class specifier.
--
-- basic_declaration_specifier :- <permute> type_qualifier* storage_class+ basic_type_name+
--
--   GNU extensions
--     arbitrary interleaved __attribute__ annotations
--
basic_declaration_specifier :: { Reversed [CDeclSpec] }
basic_declaration_specifier
  : declaration_qualifier_list basic_type_name
  	{ $1 `snoc` CTypeSpec $2 }

  | basic_type_specifier storage_class
  	{ $1 `snoc` CStorageSpec $2 }

  | basic_declaration_specifier declaration_qualifier
  	{ $1 `snoc` $2 }

  | basic_declaration_specifier basic_type_name
  	{ $1 `snoc` CTypeSpec $2 }

  | basic_declaration_specifier attr 
  	{ $1 `rappend` (liftCAttrs $2) } 


-- A mixture of type qualifiers and basic type names in any order, but
-- containing at least one basic type name.
--
-- basic_type_specifier :- <permute> type_qualifier* basic_type_name+
--
--   GNU extensions
--     arbitrary interleaved __attribute__ annotations
--
basic_type_specifier :: { Reversed [CDeclSpec] }
basic_type_specifier
  -- Arithmetic or void
  : basic_type_name
  	{ singleton (CTypeSpec $1) }

  | attrs basic_type_name
  	{ (reverseList $ liftCAttrs $1) `snoc` (CTypeSpec $2) }

  | type_qualifier_list basic_type_name
  	{ rmap CTypeQual $1 `snoc` CTypeSpec $2 }

  | type_qualifier_list attrs basic_type_name
  	{ rmap CTypeQual $1 `rappend` (liftCAttrs $2) `snoc` CTypeSpec $3 }

  | basic_type_specifier type_qualifier
  	{ $1 `snoc` CTypeQual $2 }

  | basic_type_specifier basic_type_name
  	{ $1 `snoc` CTypeSpec $2 }

  | basic_type_specifier attr
     { $1 `rappend` (liftCAttrs $2) } 


-- A named or anonymous struct, union or enum type along with at least one
-- storage class and any mix of type qualifiers.
-- 
-- * Summary: 
--   sue_declaration_specifier :- <permute> type_qualifier* storage_class+ elaborated_type_name
--
sue_declaration_specifier :: { Reversed [CDeclSpec] }
sue_declaration_specifier
  : declaration_qualifier_list elaborated_type_name
  	{ $1 `snoc` CTypeSpec $2 }

  | sue_type_specifier storage_class
  	{ $1 `snoc` CStorageSpec $2 }

  | sue_declaration_specifier declaration_qualifier
  	{ $1 `snoc` $2 }
  	
  | sue_declaration_specifier attr 
  	{ $1 }


-- A struct, union or enum type (named or anonymous) with optional leading and
-- trailing type qualifiers.
--
-- * Summary: 
--   sue_type_specifier :- <permute> type_qualifier* elaborated_type_name
--
-- * GNU Extensions: records __attribute__ annotations
--
sue_type_specifier :: { Reversed [CDeclSpec] }
sue_type_specifier
  -- struct/union/enum
  : elaborated_type_name
  	{ singleton (CTypeSpec $1) }

  | attrs elaborated_type_name
  	{ (reverseList $ liftCAttrs $1) `snoc` (CTypeSpec $2) }

  | type_qualifier_list elaborated_type_name
  	{ rmap CTypeQual $1 `snoc` CTypeSpec $2 }

  | type_qualifier_list attrs elaborated_type_name
  	{ rmap CTypeQual  $1 `rappend` (liftCAttrs $2) `snoc` CTypeSpec $3 }

  | sue_type_specifier type_qualifier
  	{ $1 `snoc` CTypeQual $2 }

  | sue_type_specifier attr
    { $1 `rappend` (liftCAttrs $2) }


-- A typedef'ed type identifier with at least one storage qualifier and any
-- number of type qualifiers
--
-- * Summary:
--   typedef_declaration_specifier :- <permute> type_qualifier* storage_class+ tyident
--
-- * Note:
--   the tyident can also be a: typeof '(' ... ')'
--
typedef_declaration_specifier :: { Reversed [CDeclSpec] }
typedef_declaration_specifier
  : typedef_type_specifier storage_class
  	{ $1 `snoc` CStorageSpec $2 }
  	
  | declaration_qualifier_list tyident
  	{% withAttrs $1 $ \at -> $1 `snoc` CTypeSpec (CTypeDef $2 at) }

  | declaration_qualifier_list typeof '(' expression ')'
  	{% withAttrs $1 $ \at -> $1 `snoc` CTypeSpec (CTypeOfExpr $4 at) }

  | declaration_qualifier_list typeof '(' type_name ')'
  	{% withAttrs $1 $ \at -> $1 `snoc` CTypeSpec (CTypeOfType $4 at) }

  | typedef_declaration_specifier declaration_qualifier
  	{ $1 `snoc` $2 }

  | typedef_declaration_specifier attr
  	{ $1 `rappend` (liftCAttrs $2) }


-- typedef'ed type identifier with optional leading and trailing type qualifiers
--
-- * Summary:
--   type_qualifier* ( tyident | typeof '('...')' ) type_qualifier*
--
typedef_type_specifier :: { Reversed [CDeclSpec] }
typedef_type_specifier
  : tyident
  	{% withAttrs $1 $ \at -> singleton (CTypeSpec (CTypeDef $1 at)) }

  | typeof '(' expression ')'
  	{% withAttrs $1 $ \at -> singleton (CTypeSpec (CTypeOfExpr $3 at)) }

  | typeof '(' type_name ')'
  	{% withAttrs $1 $ \at -> singleton (CTypeSpec (CTypeOfType $3 at)) }

  | type_qualifier_list tyident
  	{% withAttrs $2 $ \at -> rmap CTypeQual  $1 `snoc` CTypeSpec (CTypeDef $2 at) }

  | type_qualifier_list typeof '(' expression ')'
  	{% withAttrs $2 $ \at -> rmap CTypeQual  $1 `snoc` CTypeSpec (CTypeOfExpr $4 at) }

  | type_qualifier_list typeof '(' type_name ')'
  	{% withAttrs $2 $ \at -> rmap CTypeQual  $1 `snoc` CTypeSpec (CTypeOfType $4 at) }

  -- repeat with attrs (this could be easier if type qualifier list wouldn't allow leading attributes)
  | attrs tyident
  	{% withAttrs $2 $ \at -> reverseList (liftCAttrs $1) `snoc` (CTypeSpec (CTypeDef $2 at)) }

  | attrs typeof '(' expression ')'
  	{% withAttrs $2 $ \at -> reverseList (liftCAttrs $1) `snoc`  (CTypeSpec (CTypeOfExpr $4 at)) }

  | attrs typeof '(' type_name ')'
  	{% withAttrs $2 $ \at -> reverseList (liftCAttrs $1) `snoc`  (CTypeSpec (CTypeOfType $4 at)) }

  | type_qualifier_list attrs tyident
  	{% withAttrs $2 $ \at -> rmap CTypeQual  $1 `rappend` (liftCAttrs $2) `snoc` CTypeSpec (CTypeDef $3 at) }

  | type_qualifier_list attrs typeof '(' expression ')'
  	{% withAttrs $2 $ \at -> rmap CTypeQual  $1 `rappend` (liftCAttrs $2) `snoc` CTypeSpec (CTypeOfExpr $5 at) }

  | type_qualifier_list attrs typeof '(' type_name ')'
  	{% withAttrs $2 $ \at -> rmap CTypeQual  $1 `rappend` (liftCAttrs $2) `snoc` CTypeSpec (CTypeOfType $5 at) }

  | typedef_type_specifier type_qualifier
  	{ $1 `snoc` CTypeQual $2 }

  | typedef_type_specifier attr
  	{ $1 `rappend` (liftCAttrs $2) }


-- A named or anonymous struct, union or enum type.
--
-- * Summary:
--   (struct|union|enum) (identifier? '{' ... '}' | identifier)
--
elaborated_type_name :: { CTypeSpec }
elaborated_type_name
  : struct_or_union_specifier	{% withAttrs $1 $ CSUType $1 }
  | enum_specifier		{% withAttrs $1 $ CEnumType $1 }


-- parse C structure or union declaration (C99 6.7.2.1)
--
-- * Summary:
--    (struct|union) (identifier? '{' ... '}' | identifier)
--
struct_or_union_specifier :: { CStructUnion }
struct_or_union_specifier
  : struct_or_union attrs_opt identifier '{' struct_declaration_list  '}'
  	{% withAttrs $1 $ CStruct (unL $1) (Just $3) (Just$ reverse $5) $2 }

  | struct_or_union attrs_opt '{' struct_declaration_list  '}'
  	{% withAttrs $1 $ CStruct (unL $1) Nothing   (Just$ reverse $4) $2 }

  | struct_or_union attrs_opt identifier
  	{% withAttrs $1 $ CStruct (unL $1) (Just $3) Nothing $2 }


struct_or_union :: { Located CStructTag }
struct_or_union
  : struct			{ L CStructTag (posOf $1) }
  | union			{ L CUnionTag (posOf $1) }


struct_declaration_list :: { Reversed [CDecl] }
struct_declaration_list
  : {- empty -}						{ empty }
  | struct_declaration_list ';'				{ $1 }
  | struct_declaration_list struct_declaration		{ $1 `snoc` $2 }


-- parse C structure declaration (C99 6.7.2.1)
--
struct_declaration :: { CDecl }
struct_declaration
  : struct_declaring_list ';'
  	{ case $1 of CDecl declspecs dies at -> CDecl declspecs (List.reverse dies) at }

  | struct_default_declaring_list attrs_opt ';'
  	{ case $1 of CDecl declspecs dies at -> CDecl (declspecs ++ liftCAttrs $2) (List.reverse dies) at }

  | "__extension__" struct_declaration	{ $2 } 


-- 
--  * Note: doesn't redeclare typedef
--
--  TODO: FIXME: AST doesn't allow recording attributes of unnamed struct field
struct_default_declaring_list :: { CDecl }
struct_default_declaring_list
  : type_qualifier_list attrs_opt struct_identifier_declarator
  	{% withAttrs $1 $ case $3 of (d,s) -> CDecl (liftTypeQuals $1 ++ liftCAttrs $2) [(d,Nothing,s)] }

  -- GNU extension: __attribute__ as only type qualifier
  | attrs struct_identifier_declarator 
    {% withAttrs $1 $ case $2 of (d,s) -> CDecl (liftCAttrs $1) [(d,Nothing,s)] }

  | struct_default_declaring_list ',' attrs_opt struct_identifier_declarator 
  	{ case $1 of
            CDecl declspecs dies at ->
              case $4 of
                (Just d,s) -> CDecl declspecs ((Just $ appendDeclrAttrs $3 d,Nothing,s) : dies) at 
                (Nothing,s) -> CDecl declspecs ((Nothing,Nothing,s) : dies) at } -- FIXME                

-- * GNU extensions:
--     allow anonymous nested structures and unions
--
struct_declaring_list :: { CDecl }
struct_declaring_list
  : type_specifier struct_declarator attrs_opt
  	{% withAttrs $1 $ case $2 of (d,s) -> CDecl ($1++liftCAttrs $3) [(d,Nothing,s)] }

  | struct_declaring_list ',' attrs_opt struct_declarator attrs_opt
  	{ case $1 of
            CDecl declspecs dies attr ->
              case $4 of
                (Just d,s) -> CDecl declspecs ((Just$ appendDeclrAttrs $3 d,Nothing,s) : dies) attr
                (Nothing,s) -> CDecl declspecs ((Nothing,Nothing,s) : dies) attr }

  -- FIXME: We're being far too liberal in the parsing here, we really want to just
  -- allow unnamed struct and union fields but we're actually allowing any
  -- unnamed struct member. Making it allow only unnamed structs or unions in
  -- the parser is far too tricky, it makes things ambiguous. So we'll have to
  -- diagnose unnamed fields that are not structs/unions in a later stage.
  
  -- Note that a plain type specifier can have a trailing attribute 
  
  | type_specifier
     {% withAttrs $1 $ CDecl $1 []  }


-- parse C structure declarator (C99 6.7.2.1)
--
struct_declarator :: { (Maybe CDeclr, Maybe CExpr) }
struct_declarator
  : declarator					{ (Just $1, Nothing) }
  | ':' constant_expression			{ (Nothing, Just $2) }
  | declarator ':' constant_expression		{ (Just $1, Just $3) }


struct_identifier_declarator :: { (Maybe CDeclr, Maybe CExpr) }
struct_identifier_declarator
  : identifier_declarator				{ (Just $1, Nothing) }
  | ':' constant_expression				{ (Nothing, Just $2) }
  | identifier_declarator ':' constant_expression	{ (Just $1, Just $3) }


-- parse C enumeration declaration (C99 6.7.2.2)
--
-- * Summary:
--   enum (identifier? '{' ... '}' | identifier)
--
enum_specifier :: { CEnum }
enum_specifier
  : enum attrs_opt '{' enumerator_list '}'
  	{% withAttrs $1 $ CEnum Nothing   (reverse $4) $2 }

  | enum attrs_opt '{' enumerator_list ',' '}'
  	{% withAttrs $1 $ CEnum Nothing   (reverse $4) $2 }

  | enum attrs_opt identifier '{' enumerator_list '}'
  	{% withAttrs $1 $ CEnum (Just $3) (reverse $5) $2 }

  | enum attrs_opt identifier '{' enumerator_list ',' '}'
  	{% withAttrs $1 $ CEnum (Just $3) (reverse $5) $2 }

  | enum attrs_opt identifier
  	{% withAttrs $1 $ CEnum (Just $3) [] $2           }
  
enumerator_list :: { Reversed [(Ident, Maybe CExpr)] }
enumerator_list
  : enumerator					{ singleton $1 }
  | enumerator_list ',' enumerator		{ $1 `snoc` $3 }


enumerator :: { (Ident, Maybe CExpr) }
enumerator
  : identifier					{ ($1, Nothing) }
  | identifier '=' constant_expression		{ ($1, Just $3) }


-- parse C type qualifier (C99 6.7.3)
--
type_qualifier :: { CTypeQual }
type_qualifier
  : const		{% withAttrs $1 $ CConstQual }
  | volatile		{% withAttrs $1 $ CVolatQual }
  | restrict		{% withAttrs $1 $ CRestrQual }
  | inline		{% withAttrs $1 $ CInlinQual }

-- a list containing at least one type_qualifier (const, volatile, restrict, inline)
--    and additionally CAttrs
type_qualifier_list :: { Reversed [CTypeQual] }
type_qualifier_list
  : attrs_opt type_qualifier	             { reverseList (map CAttrQual $1) `snoc` $2 }
  | type_qualifier_list type_qualifier	     { $1 `snoc` $2 }
  | type_qualifier_list attrs type_qualifier { ($1 `rappend` map CAttrQual $2) `snoc` $3}	
  
-- parse C declarator (C99 6.7.5)
--
declarator :: { CDeclr }
declarator
  : identifier_declarator		{ $1 }
  | typedef_declarator			{ $1 }


-- Parse GNU C's asm annotations
--
-- Those annotations allow to give an assembler name to a function or identifier.
asm_opt :: { Maybe CStrLit }
asm_opt
  : {- empty -}				          { Nothing }
  | asm '(' string_literal ')'	{ Just $3 }

--
-- typedef_declarator :-

typedef_declarator :: { CDeclr }
typedef_declarator
  -- would be ambiguous as parameter
  : paren_typedef_declarator		{ $1 }
  
  -- not ambiguous as param
  | parameter_typedef_declarator	{ $1 }


-- parameter_typedef_declarator :- tyident declarator_postfix?
--                              | '(' attrs? clean_typedef_declarator ')' declarator_postfix?
--                              |  '*' attrs? type_qualifier_list? parameter_typedef_declarator
--
parameter_typedef_declarator :: { CDeclr }
parameter_typedef_declarator
  : tyident
  	{% withAttrs $1 $ mkVarDeclr $1 }

  | tyident postfixing_abstract_declarator
  	{% withAttrs $1 $ \at -> $2 (mkVarDeclr $1 at) }

  | clean_typedef_declarator
  	{ $1 }


-- The  following have at least one '*'.
-- There is no (redundant) '(' between the '*' and the tyident.
--
-- clean_typedef_declarator :-  '(' attrs? clean_typedef_declarator ')' declarator_postfix?
--                            | '*' attrs? type_qualifier_list? parameter_typedef_declarator
--
clean_typedef_declarator :: { CDeclr }
clean_typedef_declarator
  : clean_postfix_typedef_declarator
  	{ $1 }

  | '*' parameter_typedef_declarator
  	{% withAttrs $1 $ CPtrDeclr [] $2 }

  | '*' attrs parameter_typedef_declarator
  	{% withCAttrs $1 $2 $ CPtrDeclr [] $3 }

  | '*' type_qualifier_list  parameter_typedef_declarator
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) $3 }

  | '*' type_qualifier_list attrs parameter_typedef_declarator
  	{% withCAttrs $1 $3 $ CPtrDeclr (reverse $2) $4 }

-- clean_postfix_typedef_declarator :- ( attrs? clean_typedef_declarator ) declarator_postfix?
--
clean_postfix_typedef_declarator :: { CDeclr }
clean_postfix_typedef_declarator
  : '(' clean_typedef_declarator ')'						              { $2 }
  | '(' clean_typedef_declarator ')' postfixing_abstract_declarator		  { $4 $2 }
  | '(' attrs clean_typedef_declarator ')'	                              { appendDeclrAttrs $2 $3 }
  | '(' attrs clean_typedef_declarator ')' postfixing_abstract_declarator { appendDeclrAttrs $2 ($5 $3) }


-- The following have a redundant '(' placed
-- immediately to the left of the tyident
--
paren_typedef_declarator :: { CDeclr }
paren_typedef_declarator
  : paren_postfix_typedef_declarator
  	{ $1 }

  -- redundant paren
  | '*' '(' simple_paren_typedef_declarator ')'
  	{% withAttrs $1 $ CPtrDeclr [] $3 }

  | '*' type_qualifier_list '(' simple_paren_typedef_declarator ')'
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) $4 }
  | '*' type_qualifier_list attrs '(' simple_paren_typedef_declarator ')'
  	{% withCAttrs $1 $3 $ CPtrDeclr (reverse $2) $5 }

  | '*' paren_typedef_declarator
  	{% withAttrs $1 $ CPtrDeclr [] $2 }

  | '*' type_qualifier_list paren_typedef_declarator
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) $3 }
  | '*' type_qualifier_list attrs paren_typedef_declarator
  	{% withCAttrs $1 $3 $ CPtrDeclr (reverse $2) $4 }

-- redundant paren to left of tname
paren_postfix_typedef_declarator :: { CDeclr }
paren_postfix_typedef_declarator
  : '(' paren_typedef_declarator ')'
  	{ $2 }

  -- redundant paren
  | '(' simple_paren_typedef_declarator postfixing_abstract_declarator ')'
  	{ $3 $2 }

  | '(' paren_typedef_declarator ')' postfixing_abstract_declarator
  	{ $4 $2 }


-- Just a type name in any number of nested brackets
--
simple_paren_typedef_declarator :: { CDeclr }
simple_paren_typedef_declarator
  : tyident
  	{% withAttrs $1 $ mkVarDeclr $1 }

  | '(' simple_paren_typedef_declarator ')'
  	{ $2 }

--
-- Declarators
-- * Summary
--   declarator :- ( '*' (type_qualifier | attr)* )* ident ( array_decl | "(" parameter-list ")" )?
--      + additional parenthesis
--
identifier_declarator :: { CDeclr }
identifier_declarator
  : unary_identifier_declarator			{ $1 }
  | paren_identifier_declarator			{ $1 }


unary_identifier_declarator :: { CDeclr }
unary_identifier_declarator
  : postfix_identifier_declarator
  	{ $1 }

  | '*' identifier_declarator
  	{% withAttrs $1 $ CPtrDeclr [] $2 }

  | '*' attrs identifier_declarator 
  	{% withCAttrs $1 $2 $ CPtrDeclr [] $3 }

  | '*' type_qualifier_list identifier_declarator  
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) $3 }

  | '*' type_qualifier_list attrs identifier_declarator
  	{% withCAttrs $1 $3 $ CPtrDeclr (reverse $2) $4 }

postfix_identifier_declarator :: { CDeclr }
postfix_identifier_declarator
  : paren_identifier_declarator postfixing_abstract_declarator
  	{ $2 $1 }

   | '('  unary_identifier_declarator ')'
   	{ $2 }
 
   | '(' unary_identifier_declarator ')' postfixing_abstract_declarator
   	{ $4 $2 }

   | '(' attrs unary_identifier_declarator ')'
     { appendDeclrAttrs $2 $3 }
 
   | '(' attrs unary_identifier_declarator ')' postfixing_abstract_declarator
     { appendDeclrAttrs $2 ($5 $3) }


-- just an identifier in any number of nested parenthesis
paren_identifier_declarator :: { CDeclr }
paren_identifier_declarator
  : ident
  	{% withAttrs $1 $ mkVarDeclr $1 }

  | '(' paren_identifier_declarator ')'
  	{ $2 }

  | '(' attrs paren_identifier_declarator ')' 
  	{ appendDeclrAttrs $2 $3 }



old_function_declarator :: { CDeclr }
old_function_declarator
  : postfix_old_function_declarator
  	{ $1 }

  | '*' old_function_declarator
  	{% withAttrs $1 $ CPtrDeclr [] $2 } -- FIXME: no attr possible here ???

  | '*' type_qualifier_list old_function_declarator
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) $3 }

postfix_old_function_declarator :: { CDeclr }
postfix_old_function_declarator
  : paren_identifier_declarator '(' identifier_list ')'
  	{% withAttrs $2 $ CFunDeclr $1 (Left $ reverse $3) [] }

  | '(' old_function_declarator ')'
  	{ $2 }

  | '(' old_function_declarator ')' postfixing_abstract_declarator
  	{ $4 $2 }


-- parse C parameter type list (C99 6.7.5)
--
parameter_type_list :: { ([CDecl], Bool) }
parameter_type_list
  : {- empty -}				{ ([], False)}
  | parameter_list			{ (reverse $1, False) }
  | parameter_list ',' "..."		{ (reverse $1, True) }

parameter_list :: { Reversed [CDecl] }
parameter_list
  : parameter_declaration				{ singleton $1 }
  | parameter_list ',' parameter_declaration	{ $1 `snoc` $3 }

parameter_declaration :: { CDecl }
parameter_declaration
  : declaration_specifier
  	{% withAttrs $1 $ CDecl $1 [] }

  | declaration_specifier abstract_declarator
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | declaration_specifier identifier_declarator attrs_opt        -- FIX 0700
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | declaration_specifier parameter_typedef_declarator attrs_opt -- FIX 0700
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | declaration_qualifier_list
  	{% withAttrs $1 $ CDecl (reverse $1) [] }

  | declaration_qualifier_list abstract_declarator
  	{% withAttrs $1 $ CDecl (reverse $1) [(Just $2, Nothing, Nothing)] }

  | declaration_qualifier_list identifier_declarator attrs_opt -- FIX 0700
  	{% withAttrs $1 $ CDecl (reverse $1) [(Just $2, Nothing, Nothing)] }

  | type_specifier
  	{% withAttrs $1 $ CDecl $1 [] }

  | type_specifier abstract_declarator
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | type_specifier identifier_declarator attrs_opt -- FIX 0700
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | type_specifier parameter_typedef_declarator attrs_opt -- FIX 0700
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  | type_qualifier_list 
  	{% withAttrs $1 $ CDecl (liftTypeQuals $1) [] }
  | type_qualifier_list attr
  	{% withAttrs $1 $ CDecl (liftTypeQuals $1 ++ liftCAttrs $2) [] }

  | type_qualifier_list abstract_declarator
  	{% withAttrs $1 $ CDecl (liftTypeQuals $1) [(Just $2, Nothing, Nothing)] }

  | type_qualifier_list identifier_declarator attrs_opt
  	{% withAttrs $1 $ CDecl (liftTypeQuals $1) [(Just (appendDeclrAttrs $3 $2), Nothing, Nothing)] }


identifier_list :: { Reversed [Ident] }
identifier_list
  : ident				{ singleton $1 }
  | identifier_list ',' ident		{ $1 `snoc` $3 }


-- parse C type name (C99 6.7.6)
--
type_name :: { CDecl }
type_name
  :  type_specifier
  	{% withAttrs $1 $ CDecl $1 [] }

  |  type_specifier abstract_declarator
  	{% withAttrs $1 $ CDecl $1 [(Just $2, Nothing, Nothing)] }

  |  type_qualifier_list attr
  	{% withAttrs $1 $ CDecl (liftTypeQuals $1 ++ liftCAttrs $2) [] }

  |  type_qualifier_list abstract_declarator
  	{% withAttrs $1 $ CDecl (liftTypeQuals $1) [(Just $2, Nothing, Nothing)] }

-- parse C abstract declarator (C99 6.7.6)
--
-- postfix starts with '('
-- postfixing starts with '(' or '['
-- unary start with '*'
abstract_declarator :: { CDeclr }
abstract_declarator
  : unary_abstract_declarator			  { $1 }
  | postfix_abstract_declarator			{ $1 }
  | postfixing_abstract_declarator  { $1 emptyDeclr }

--
-- FIXME
--  | postfixing_abstract_declarator attrs_opt	{ $1 emptyDeclr }


postfixing_abstract_declarator :: { CDeclr -> CDeclr }
postfixing_abstract_declarator
  : array_abstract_declarator
  	{ $1 }

  | '(' parameter_type_list ')'
  	{% withAttrs $1 $ \at declr -> case $2 of
             (params, variadic) -> CFunDeclr declr (Right (params,variadic)) [] at }


-- * TODO: Note that we recognise but ignore the C99 static keyword (see C99 6.7.5.3)
--
-- * TODO: We do not distinguish in the AST between incomplete array types and
-- complete variable length arrays ([ '*' ] means the latter). (see C99 6.7.5.2)
--
array_abstract_declarator :: { CDeclr -> CDeclr }
array_abstract_declarator
  : postfix_array_abstract_declarator
  	{ $1 }

  | array_abstract_declarator postfix_array_abstract_declarator
  	{ \decl -> $2 ($1 decl) }

-- 
-- TODO: record static
postfix_array_abstract_declarator :: { CDeclr -> CDeclr }
postfix_array_abstract_declarator
  : '[' assignment_expression_opt ']'
  	{% withAttrs $1 $ \at declr -> CArrDeclr declr [] $2 at }

  | '[' attrs assignment_expression_opt ']'
  	{% withCAttrsPF $1 $2 $ \at declr -> CArrDeclr declr [] $3 at }

  | '[' type_qualifier_list assignment_expression_opt ']'
  	{% withAttrs $1 $ \at declr -> CArrDeclr declr (reverse $2) $3 at }

  | '[' type_qualifier_list attrs assignment_expression_opt ']'
  	{% withCAttrsPF $1 $3 $ \at declr -> CArrDeclr declr (reverse $2) $4 at }

  -- FIXME: static isn't recorded
  | '[' static attrs_opt assignment_expression ']' 
  	{% withCAttrsPF $1 $3 $ \at declr -> CArrDeclr declr [] (Just $4) at }

  -- FIXME: static isn't recorded
  | '[' static type_qualifier_list attrs_opt assignment_expression ']'
  	{% withCAttrsPF $1 $4 $ \at declr -> CArrDeclr declr (reverse $3) (Just $5) at }

  -- FIXME: static isn't recorded
  | '[' type_qualifier_list attrs_opt static attrs_opt assignment_expression ']'
  	{% withCAttrsPF $1 ($3 ++ $5) $ \at declr -> CArrDeclr declr (reverse $2) (Just $6) at }
 
  | '[' '*' attrs_opt ']'
  	{% withCAttrsPF $1 $3 $ \at declr -> CArrDeclr declr [] Nothing at }
  | '[' attrs '*' attrs_opt ']'
  	{% withCAttrsPF $1 ($2 ++ $4) $ \at declr -> CArrDeclr declr [] Nothing at }

  | '[' type_qualifier_list '*' attrs_opt ']'
  	{% withCAttrsPF $1 $4 $ \at declr -> CArrDeclr declr (reverse $2) Nothing at }
  | '[' type_qualifier_list attrs '*' attrs_opt ']'
  	{% withCAttrsPF $1 ($3 ++ $5) $ \at declr -> CArrDeclr declr (reverse $2) Nothing at }

unary_abstract_declarator :: { CDeclr }
unary_abstract_declarator
  : '*'
  	{% withAttrs $1 $ CPtrDeclr [] emptyDeclr }

  | '*' type_qualifier_list attrs_opt
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) emptyDeclr }

  | '*' abstract_declarator
  	{% withAttrs $1 $ CPtrDeclr [] $2 }

  | '*' type_qualifier_list abstract_declarator
  	{% withAttrs $1 $ CPtrDeclr (reverse $2) $3 }

  | '*' attrs
  	{% withCAttrs $1 $2 $ CPtrDeclr [] emptyDeclr }
  | '*' attrs abstract_declarator
  	{% withCAttrs $1 $2 $ CPtrDeclr [] $3 }

-- postfix_ad starts with '(', postfixing with '(' or '[', unary_abstract starts with '*'
postfix_abstract_declarator :: { CDeclr }
postfix_abstract_declarator
  : '(' unary_abstract_declarator ')'					{ $2 }
  | '(' postfix_abstract_declarator ')'					{ $2 }
  | '(' postfixing_abstract_declarator ')'				{ $2 emptyDeclr }
  | '(' unary_abstract_declarator ')' postfixing_abstract_declarator	{ $4 $2 }

-- FIX 0700
  | '(' attrs unary_abstract_declarator ')'				     	{ appendDeclrAttrs $2 $3 }
  | '(' attrs postfix_abstract_declarator ')'					{ appendDeclrAttrs $2 $3 }
  | '(' attrs postfixing_abstract_declarator ')'				{ appendDeclrAttrs $2 ($3 emptyDeclr) }
  | '(' attrs unary_abstract_declarator ')' postfixing_abstract_declarator	{ appendDeclrAttrs $2 ($5 $3) }
  | postfix_abstract_declarator attr						    { appendDeclrAttrs $2 $1 }


-- parse C initializer (C99 6.7.8)
--
initializer :: { CInit }
initializer
  : assignment_expression		{% withAttrs $1 $ CInitExpr $1 }
  | '{' initializer_list '}'		{% withAttrs $1 $ CInitList (reverse $2) }
  | '{' initializer_list ',' '}'	{% withAttrs $1 $ CInitList (reverse $2) }


initializer_opt :: { Maybe CInit }
initializer_opt
  : {- empty -}			{ Nothing }
  | '=' initializer		{ Just $2 }


initializer_list :: { Reversed CInitList }
initializer_list
  : {- empty -}						{ empty }
  | initializer						{ singleton ([],$1) }
  | designation initializer				{ singleton ($1,$2) }
  | initializer_list ',' initializer			{ $1 `snoc` ([],$3) }
  | initializer_list ',' designation initializer	{ $1 `snoc` ($3,$4) }


-- designation
--
-- * GNU extensions:
--     old style member designation: 'ident :'
--     array range designation
--
designation :: { [CDesignator] }
designation
  : designator_list '='		{ reverse $1 }
  | identifier ':'		{% withAttrs $1 $ \at -> [CMemberDesig $1 at] }
  | array_designator		{ [$1] }


designator_list :: { Reversed [CDesignator] }
designator_list
 : designator				{ singleton $1 }
 | designator_list designator		{ $1 `snoc` $2 }


designator :: { CDesignator }
designator
  : '[' constant_expression ']'		{% withAttrs $1 $ CArrDesig $2 }
  | '.' identifier			{% withAttrs $1 $ CMemberDesig $2 }
  | array_designator			{ $1 }


array_designator :: { CDesignator }
array_designator
  : '[' constant_expression "..." constant_expression ']'
  	{% withAttrs $1 $ CRangeDesig $2 $4 }


-- parse C primary expression (C99 6.5.1)
--
-- We cannot use a typedef name as a variable
--
-- * GNU extensions:
--     allow a compound statement as an expression
--     __builtin_va_arg
--     __builtin_offsetof
--     __builtin_types_compatible_p
primary_expression :: { CExpr }
primary_expression
  : ident		       {% withAttrs $1 $ CVar $1 }
  | constant	  	 {% withAttrs $1 $ CConst   $1 }
  | string_literal {% withAttrs $1 $ CConst (liftStrLit $1) }
  | '(' expression ')'	{ $2 }

  -- GNU extensions
  | '(' compound_statement ')'
  	{% withAttrs $1 $ CStatExpr $2 }

  | "__builtin_va_arg" '(' assignment_expression ',' type_name ')'
  	{% withAttrs $1 $ CBuiltinExpr . CBuiltinVaArg $3 $5 }

  | "__builtin_offsetof" '(' type_name ',' offsetof_member_designator ')'
  	{% withAttrs $1 $ CBuiltinExpr . CBuiltinOffsetOf $3 (reverse $5) }

  | "__builtin_types_compatible_p" '(' type_name ',' type_name ')'
  	{% withAttrs $1 $ CBuiltinExpr . CBuiltinTypesCompatible $3 $5 }


offsetof_member_designator :: { Reversed [CDesignator] }
offsetof_member_designator
  : identifier						                        {% withAttrs $1 $ singleton . CMemberDesig $1 }
  | offsetof_member_designator '.' identifier		  {% withAttrs $3 $ ($1 `snoc`) . CMemberDesig $3 }
  | offsetof_member_designator '[' expression ']'	{% withAttrs $3 $ ($1 `snoc`) . CArrDesig $3 }


-- parse C postfix expression (C99 6.5.2)
--
postfix_expression :: { CExpr }
postfix_expression
  : primary_expression
  	{ $1 }

  | postfix_expression '[' expression ']'
  	{% withAttrs $2 $ CIndex $1 $3 }

  | postfix_expression '(' ')'
  	{% withAttrs $2 $ CCall $1 [] }

  | postfix_expression '(' argument_expression_list ')'
  	{% withAttrs $2 $ CCall $1 (reverse $3) }

  | postfix_expression '.' identifier
  	{% withAttrs $2 $ CMember $1 $3 False }

  | postfix_expression "->" identifier
  	{% withAttrs $2 $ CMember $1 $3 True }

  | postfix_expression "++"
  	{% withAttrs $2 $ CUnary CPostIncOp $1 }

  | postfix_expression "--"
  	{% withAttrs $2 $ CUnary CPostDecOp $1 }

  | '(' type_name ')' '{' initializer_list '}'
  	{% withAttrs $4 $ CCompoundLit $2 (reverse $5) }

  | '(' type_name ')' '{' initializer_list ',' '}'
  	{% withAttrs $4 $ CCompoundLit $2 (reverse $5) }


argument_expression_list :: { Reversed [CExpr] }
argument_expression_list
  : assignment_expression				{ singleton $1 }
  | argument_expression_list ',' assignment_expression	{ $1 `snoc` $3 }


-- parse C unary expression (C99 6.5.3)
--
-- * GNU extensions:
--     'alignof' expression or type
--     '__real' and '__imag' expression
--     '__extension__' to suppress warnings about extensions
--     allow taking address of a label with: && label
--
unary_expression :: { CExpr }
unary_expression
  : postfix_expression			{ $1 }
  | "++" unary_expression		{% withAttrs $1 $ CUnary CPreIncOp $2 }
  | "--" unary_expression		{% withAttrs $1 $ CUnary CPreDecOp $2 }
  | "__extension__" cast_expression	{ $2 }
  | unary_operator cast_expression	{% withAttrs $1 $ CUnary (unL $1) $2 }
  | sizeof unary_expression		{% withAttrs $1 $ CSizeofExpr $2 }
  | sizeof '(' type_name ')'		{% withAttrs $1 $ CSizeofType $3 }
  -- GNU: alignof, complex and && extension
  | alignof unary_expression		{% withAttrs $1 $ CAlignofExpr $2 }
  | alignof '(' type_name ')'		{% withAttrs $1 $ CAlignofType $3 }
  | "__real__" unary_expression    {% withAttrs $1 $ CComplexReal $2 }
  | "__imag__" unary_expression    {% withAttrs $1 $ CComplexImag $2 }
  | "&&" identifier			{% withAttrs $1 $ CLabAddrExpr $2 }


unary_operator :: { Located CUnaryOp }
unary_operator
  : '&'		{ L CAdrOp  (posOf $1) }
  | '*'		{ L CIndOp  (posOf $1) }
  | '+'		{ L CPlusOp (posOf $1) }
  | '-'		{ L CMinOp  (posOf $1) }
  | '~'		{ L CCompOp (posOf $1) }
  | '!'		{ L CNegOp  (posOf $1) }


-- parse C cast expression (C99 6.5.4)
--
cast_expression :: { CExpr }
cast_expression
  : unary_expression			{ $1 }
  | '(' type_name ')' cast_expression	{% withAttrs $1 $ CCast $2 $4 }


-- parse C multiplicative expression (C99 6.5.5)
--
multiplicative_expression :: { CExpr }
multiplicative_expression
  : cast_expression
  	{ $1 }

  | multiplicative_expression '*' cast_expression
  	{% withAttrs $2 $ CBinary CMulOp $1 $3 }

  | multiplicative_expression '/' cast_expression
  	{% withAttrs $2 $ CBinary CDivOp $1 $3 }

  | multiplicative_expression '%' cast_expression
  	{% withAttrs $2 $ CBinary CRmdOp $1 $3 }


-- parse C additive expression (C99 6.5.6)
--
additive_expression :: { CExpr }
additive_expression
  : multiplicative_expression
  	{ $1 }

  | additive_expression '+' multiplicative_expression
  	{% withAttrs $2 $ CBinary CAddOp $1 $3 }

  | additive_expression '-' multiplicative_expression
  	{% withAttrs $2 $ CBinary CSubOp $1 $3 }


-- parse C shift expression (C99 6.5.7)
--
shift_expression :: { CExpr }
shift_expression
  : additive_expression
  	{ $1 }

  | shift_expression "<<" additive_expression
  	{% withAttrs $2 $ CBinary CShlOp $1 $3 }

  | shift_expression ">>" additive_expression
  	{% withAttrs $2 $ CBinary CShrOp $1 $3 }


-- parse C relational expression (C99 6.5.8)
--
relational_expression :: { CExpr }
relational_expression
  : shift_expression
  	{ $1 }

  | relational_expression '<' shift_expression
  	{% withAttrs $2 $ CBinary CLeOp $1 $3 }

  | relational_expression '>' shift_expression
  	{% withAttrs $2 $ CBinary CGrOp $1 $3 }

  | relational_expression "<=" shift_expression
  	{% withAttrs $2 $ CBinary CLeqOp $1 $3 }

  | relational_expression ">=" shift_expression
  	{% withAttrs $2 $ CBinary CGeqOp $1 $3 }


-- parse C equality expression (C99 6.5.9)
--
equality_expression :: { CExpr }
equality_expression
  : relational_expression
  	{ $1 }

  | equality_expression "==" relational_expression
  	{% withAttrs $2 $ CBinary CEqOp  $1 $3 }

  | equality_expression "!=" relational_expression
  	{% withAttrs $2 $ CBinary CNeqOp $1 $3 }


-- parse C bitwise and expression (C99 6.5.10)
--
and_expression :: { CExpr }
and_expression
  : equality_expression
  	{ $1 }

  | and_expression '&' equality_expression
  	{% withAttrs $2 $ CBinary CAndOp $1 $3 }


-- parse C bitwise exclusive or expression (C99 6.5.11)
--
exclusive_or_expression :: { CExpr }
exclusive_or_expression
  : and_expression
  	{ $1 }

  | exclusive_or_expression '^' and_expression
  	{% withAttrs $2 $ CBinary CXorOp $1 $3 }


-- parse C bitwise or expression (C99 6.5.12)
--
inclusive_or_expression :: { CExpr }
inclusive_or_expression
  : exclusive_or_expression
  	{ $1 }

  | inclusive_or_expression '|' exclusive_or_expression
  	{% withAttrs $2 $ CBinary COrOp $1 $3 }


-- parse C logical and expression (C99 6.5.13)
--
logical_and_expression :: { CExpr }
logical_and_expression
  : inclusive_or_expression
  	{ $1 }

  | logical_and_expression "&&" inclusive_or_expression
  	{% withAttrs $2 $ CBinary CLndOp $1 $3 }


-- parse C logical or expression (C99 6.5.14)
--
logical_or_expression :: { CExpr }
logical_or_expression
  : logical_and_expression
  	{ $1 }

  | logical_or_expression "||" logical_and_expression
  	{% withAttrs $2 $ CBinary CLorOp $1 $3 }


-- parse C conditional expression (C99 6.5.15)
--
-- * GNU extensions:
--     omitting the `then' part
conditional_expression :: { CExpr }
conditional_expression
  : logical_or_expression
  	{ $1 }

  | logical_or_expression '?' expression ':' conditional_expression
  	{% withAttrs $2 $ CCond $1 (Just $3) $5 }

  | logical_or_expression '?' ':' conditional_expression
  	{% withAttrs $2 $ CCond $1 Nothing $4 }


-- parse C assignment expression (C99 6.5.16)
--
-- * NOTE: LHS of assignment is more restricted than in gcc.
--         `x ? y : z = 3' parses in gcc as `(x ? y : z) = 3',
--         but `x ? y : z' is not an unary expression.
assignment_expression :: { CExpr }
assignment_expression
  : conditional_expression
  	{ $1 }

  | unary_expression assignment_operator assignment_expression
  	{% withAttrs $2 $ CAssign (unL $2) $1 $3 }


assignment_operator :: { Located CAssignOp }
assignment_operator
  : '='			{ L CAssignOp (posOf $1) }
  | "*="		{ L CMulAssOp (posOf $1) }
  | "/="		{ L CDivAssOp (posOf $1) }
  | "%="		{ L CRmdAssOp (posOf $1) }
  | "+="		{ L CAddAssOp (posOf $1) }
  | "-="		{ L CSubAssOp (posOf $1) }
  | "<<="		{ L CShlAssOp (posOf $1) }
  | ">>="		{ L CShrAssOp (posOf $1) }
  | "&="		{ L CAndAssOp (posOf $1) }
  | "^="		{ L CXorAssOp (posOf $1) }
  | "|="		{ L COrAssOp  (posOf $1) }


-- parse C expression (C99 6.5.17)
--
expression :: { CExpr }
expression
  : assignment_expression
  	{ $1 }

  | assignment_expression ',' comma_expression
  	{% let es = reverse $3 in withAttrs es $ CComma ($1:es) }

comma_expression :: { Reversed [CExpr] }
comma_expression
  : assignment_expression			{ singleton $1 }
  | comma_expression ',' assignment_expression	{ $1 `snoc` $3 }


-- The following was used for clarity
expression_opt :: { Maybe CExpr }
expression_opt
  : {- empty -}		{ Nothing }
  | expression		{ Just $1 }


-- The following was used for clarity
assignment_expression_opt :: { Maybe CExpr }
assignment_expression_opt
  : {- empty -}				{ Nothing }
  | assignment_expression		{ Just $1 }


-- parse C constant expression (C99 6.6)
--
constant_expression :: { CExpr }
constant_expression
  : conditional_expression			{ $1 }


-- parse C constants
--
constant :: { CConst }
constant
  : cint	  {% withAttrs $1 $ case $1 of CTokILit _ i -> CIntConst i }
  | cchar	  {% withAttrs $1 $ case $1 of CTokCLit _ c -> CCharConst c }
  | cfloat	{% withAttrs $1 $ case $1 of CTokFLit _ f -> CFloatConst f }


string_literal :: { CStrLit }
string_literal
  : cstr
  	{% withAttrs $1 $ case $1 of CTokSLit _ s -> CStrLit s }

  | cstr string_literal_list
  	{% withAttrs $1 $ case $1 of CTokSLit _ s -> CStrLit (concat (s : reverse $2)) }


string_literal_list :: { Reversed [String] }
string_literal_list
  : cstr			{ case $1 of CTokSLit _ s -> singleton s }
  | string_literal_list cstr	{ case $2 of CTokSLit _ s -> $1 `snoc` s }


identifier :: { Ident }
identifier
  : ident		{ $1 }
  | tyident		{ $1 }


-- parse GNU C attribute annotation 
attrs_opt ::	{ [CAttr] }
attrs_opt
  : {- empty -}						{ [] }
  | attrs         				{ $1 }

-- GNU C attribute annotation
attrs :: { [CAttr] }
attrs
  : attr						{ $1 }
  | attrs attr	    { $1 ++ $2 }

attr :: { [CAttr] }
attr
  : "__attribute__" '(' '(' attribute_list ')' ')'	{ reverse $4 }

attribute_list :: { Reversed [CAttr] }
  : attribute						          { case $1 of Nothing -> empty; Just attr -> singleton attr } 
  | attribute_list ',' attribute	{ (maybe id (flip snoc) $3) $1 } 


attribute :: { Maybe CAttr }
attribute
  : {- empty -}						         { Nothing }
  | ident						               {% withAttrs $1 $ Just . CAttr $1  [] }
  | const						               {% withAttrs $1 $ Just . CAttr (internalIdent "const") [] }
  | ident '(' attribute_params ')' {% withAttrs $1 $ Just . CAttr $1 (reverse $3) }
  | ident '(' ')'					         {% withAttrs $1 $ Just . CAttr $1 [] }

attribute_params :: { Reversed [CExpr] }
attribute_params
  : constant_expression					              { singleton $1 }
  | attribute_params ',' constant_expression	{ $1 `snoc` $3 }


{

infixr 5 `snoc`

-- Due to the way the grammar is constructed we very often have to build lists
-- in reverse. To make sure we do this consistently and correctly we have a
-- newtype to wrap the reversed style of list:
--
newtype Reversed a = Reversed a

-- sometimes it is neccessary to reverse an unreversed list
reverseList :: [a] -> Reversed [a]
reverseList = Reversed . List.reverse

empty :: Reversed [a]
empty = Reversed []

singleton :: a -> Reversed [a]
singleton x = Reversed [x]

snoc :: Reversed [a] -> a -> Reversed [a]
snoc (Reversed xs) x = Reversed (x : xs)

rappend :: Reversed [a] -> [a] -> Reversed [a]
rappend (Reversed xs) ys = Reversed (List.reverse ys ++ xs)

appendr :: [a] -> Reversed [a] -> Reversed [a]
appendr xs (Reversed ys) = Reversed (ys ++ List.reverse xs)

rappendr :: Reversed [a] -> Reversed [a] -> Reversed [a]
rappendr (Reversed xs) (Reversed ys) = Reversed (ys ++ xs)

rmap :: (a -> b) -> Reversed [a] -> Reversed [b]
rmap f (Reversed xs) = Reversed (map f xs)

reverse :: Reversed [a] -> [a]
reverse (Reversed xs) = List.reverse xs

-- We occasionally need things to have a location when they don't naturally
-- have one built in as tokens and most AST elements do.
--
data Located a = L !a !Position

unL :: Located a -> a
unL (L a pos) = a

instance Pos (Located a) where
  posOf (L _ pos) = pos

{-# INLINE withAttrs #-}
withAttrs :: Pos node => node -> (Attrs -> a) -> P a
withAttrs node mkAttributedNode = do
  name <- getNewName
  let attrs = newAttrs (posOf node) name
  attrs `seq` return (mkAttributedNode attrs)

{-# INLINE withCAttrs #-}
withCAttrs :: Pos node => node -> [CAttr] -> (Attrs -> CDeclr) -> P CDeclr
withCAttrs node cattrs mkDeclrNode = do
  name <- getNewName
  let attrs = newAttrs (posOf node) name
  let newDeclr = appendDeclrAttrs cattrs $ mkDeclrNode attrs
  attrs `seq` newDeclr `seq` return newDeclr

-- postfixing variant
{-# INLINE withCAttrsPF #-}
withCAttrsPF :: Pos node => node -> [CAttr] -> (Attrs -> CDeclr -> CDeclr) -> P (CDeclr -> CDeclr)
withCAttrsPF node cattrs mkDeclrCtor = do
  name <- getNewName
  let attrs = newAttrs (posOf node) name
  let newDeclr = appendDeclrAttrs cattrs . mkDeclrCtor attrs
  attrs `seq` newDeclr `seq` return newDeclr


liftTypeQuals :: Reversed [CTypeQual] -> [CDeclSpec]
liftTypeQuals (Reversed tyqs) = revmap [] tyqs
  where revmap a []     = a
        revmap a (x:xs) = revmap (CTypeQual x : a) xs
  
-- lift CAttrs to DeclSpecs
-- 
liftCAttrs :: [CAttr] -> [CDeclSpec]
liftCAttrs = map (CTypeQual . CAttrQual)

-- convenient instance, the position of a list of things is the position of
-- the first thing in the list
--
instance Pos a => Pos [a] where
  posOf (x:_) = posOf x

instance Pos a => Pos (Reversed a) where
  posOf (Reversed x) = posOf x

emptyDeclr     = CVarDeclr Nothing Nothing [] (newAttrsOnlyPos nopos)
mkVarDeclr ident = CVarDeclr (Just ident) Nothing []

-- Take the identifiers and use them to update the typedef'ed identifier set
-- if the decl is defining a typedef then we add it to the set,
-- if it's a var decl then that shadows typedefed identifiers
--
doDeclIdent :: [CDeclSpec] -> CDeclr -> P ()
doDeclIdent declspecs declr =
  case getCDeclrIdent declr of
    Nothing -> return ()
    Just ident | any isTypeDef declspecs -> addTypedef ident
               | otherwise               -> shadowTypedef ident

  where isTypeDef (CStorageSpec (CTypedef _)) = True
        isTypeDef _                           = False

doFuncParamDeclIdent :: CDeclr -> P ()
doFuncParamDeclIdent (CFunDeclr _ params _ _) =
  sequence_
    [ case getCDeclrIdent declr of
        Nothing -> return ()
        Just ident -> shadowTypedef ident
    | CDecl _ dle _  <- either (const []) fst params
    , (Just declr, _, _) <- dle ]
doFuncParamDeclIdent (CPtrDeclr _ declr _) = doFuncParamDeclIdent declr -- FIXME: missing case for CArrDeclr
doFuncParamDeclIdent _ = return ()

-- extract all identifiers
getCDeclrIdent :: CDeclr -> Maybe Ident
getCDeclrIdent declr = case varDeclr declr of CVarDeclr mIdent _ _ _ -> mIdent; _ -> Nothing

-- add top level attributes for a declarator.
--
-- In the following example
--
-- > int declr1, __attribute__((a1)) * __attribute__((a2)) y() __asm__("$" "y") __attribute__((a3));
--
-- the attributes `a1' and `a3' are top-level attributes for y.
-- The (pseudo)-AST for the second declarator is
--
-- > CPtrDeclr (attr a2) 
-- >    CFunDeclr () 
-- >       CVarDeclr (asm "$y") (attrs a1 a3)
--
-- So assembler names and attributes are recorded in the VarDeclr declarator.
--
addTLDeclrAttrs :: (Maybe CStrLit, [CAttr]) -> CDeclr -> CDeclr
addTLDeclrAttrs (Nothing,[]) declr    = declr
addTLDeclrAttrs (mAsmName, newAttrs) declr = insertAttrs declr where
  insertAttrs declr = case declr of
    CVarDeclr ident oldName cattrs at ->
        case combineName mAsmName oldName of
            Left _ -> error "Attempt to overwrite asm name"
            Right newName -> CVarDeclr ident mAsmName (cattrs ++ newAttrs) at
    CPtrDeclr typeQuals innerDeclr at    -> CPtrDeclr typeQuals (insertAttrs innerDeclr) at
    CArrDeclr innerDeclr typeQuals arraySize at -> CArrDeclr (insertAttrs innerDeclr) typeQuals arraySize at
    CFunDeclr innerDeclr parameters cattrs at  -> CFunDeclr (insertAttrs innerDeclr) parameters cattrs at
  combineName Nothing Nothing = Right Nothing
  combineName Nothing oldname@(Just _)  = Right oldname
  combineName newname@(Just _) Nothing  = Right newname
  combineName (Just _) (Just _) = Left ()

happyError :: P a
happyError = parseError

-- | @parseC input initialPos@ parses the given preprocessed C-source input and return the AST or a list of error messages along with 
-- the position of the error.
parseC :: String -> Position -> Either ([String],Position) CHeader
parseC input initialPosition = 
  case execParser header input initialPosition (map fst builtinTypeNames) (namesStartingFrom 0) of
		Left header -> Right header
		Right (msg,pos) -> Left (msg,pos)


{-  
parseC :: String -> Position -> PreCST s s' CHeader
parseC input initialPosition  = do
  nameSupply <- getNameSupply
  let ns = names nameSupply
  case execParser header input
                  initialPosition (map fst builtinTypeNames) ns of
    Left header -> return header
    Right (message, position) -> raiseFatal "Error in C header file."
                                            position message
-}
}
