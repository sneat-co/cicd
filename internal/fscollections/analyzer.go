// Package fscollections finds every Firestore path that Go code builds with
// dalgo (github.com/dal-go/record and github.com/dal-go/dalgo/dal) and
// compares the paths with a list of defined collections.
//
// The analyzer follows key constructors through helper functions in any
// package or module: a function that returns a key gets a fact describing the
// path templates it can return, with its parameters left open, and every call
// of it fills them in. A path it cannot work out is reported as unresolved, so
// the check fails closed.
package fscollections

import (
	"fmt"
	"go/ast"
	"go/constant"
	"go/token"
	"go/types"
	"reflect"
	"strings"

	"golang.org/x/tools/go/analysis"
	"golang.org/x/tools/go/types/typeutil"
)

const (
	recordPkg = "github.com/dal-go/record"
	dalPkg    = "github.com/dal-go/dalgo/dal"
)

// Segment kinds.
const (
	segLit      = iota // a fixed value
	segWild            // any value, named for display
	segParam           // the value of a parameter of the enclosing function
	segKeyParam        // the path of a key-typed parameter, spliced in
)

// Seg is one segment of a path template.
type Seg struct {
	Kind  int
	Value string // the literal value, or the display name
	Index int    // parameter index for segParam and segKeyParam
}

// Path kinds.
const (
	KindDocument   = "document"
	KindCollection = "collection"
	KindGroup      = "group"
)

// Guard values for Template.GuardParam.
const (
	noGuard     = -1
	callerGuard = -2
)

// Template is one path a key expression can build.
type Template struct {
	Kind string
	Segs []Seg
	// GuardParam is the index of a string parameter whose emptiness selects
	// this template (an `if p == "" { return ... }` branch), noGuard, or
	// callerGuard when a caller passed a non-constant value for it.
	GuardParam int
	Guard      string
}

// keyFact records the templates a function can return, per result index.
type keyFact struct {
	Results [][]Template // per result index
	Uses    []Template   // paths built inside from the parameters, not returned
}

func (*keyFact) AFact() {}

func (f *keyFact) String() string {
	return fmt.Sprintf("keyTemplates(%d results, %d uses)", len(f.Results), len(f.Uses))
}

// Site is one place that builds a known path.
type Site struct {
	Path     string
	Kind     string
	Pos      token.Position
	Guard    string // non-empty when the path is built only under a condition
	Declared bool   // named by a //firestore:path comment
}

// Unresolved is one place whose path cannot be worked out.
type Unresolved struct {
	Pos    token.Position
	Func   string
	Reason string
}

// Result is the analyzer's result for one package.
type Result struct {
	Sites      []Site
	Unresolved []Unresolved
}

// Analyzer reports the Firestore paths built by a package.
var Analyzer = &analysis.Analyzer{
	Name:       "fscollections",
	Doc:        "reports the Firestore paths built with dalgo key constructors",
	Run:        run,
	FactTypes:  []analysis.Fact{new(keyFact)},
	ResultType: reflect.TypeFor[*Result](),
}

// DirectivePrefix names the paths an unresolvable site builds.
const DirectivePrefix = "//firestore:path "

type assignment struct {
	rhs   ast.Expr
	index int
	multi bool
}

type state struct {
	pass    *analysis.Pass
	local   map[*types.Func]*keyFact
	params  map[*types.Var]int
	assigns map[*types.Var][]assignment
}

type evalError string

func (e evalError) Error() string { return string(e) }

func fail(format string, args ...any) error { return evalError(fmt.Sprintf(format, args...)) }

func run(pass *analysis.Pass) (any, error) {
	st := &state{pass: pass, local: map[*types.Func]*keyFact{}}
	var decls []*ast.FuncDecl
	for _, f := range pass.Files {
		for _, d := range f.Decls {
			if fd, ok := d.(*ast.FuncDecl); ok && fd.Body != nil {
				decls = append(decls, fd)
			}
		}
	}
	// Facts of functions in this package can depend on each other: iterate
	// until nothing changes. Each round can only add information, and a
	// chain of n functions settles in n rounds.
	for round := 0; round <= len(decls); round++ {
		changed := false
		for _, fd := range decls {
			fn := pass.TypesInfo.Defs[fd.Name].(*types.Func)
			fact := st.factOf(fd, fn)
			if !reflect.DeepEqual(fact, st.local[fn]) {
				changed = true
			}
			st.local[fn] = fact
		}
		if !changed {
			break
		}
	}
	for fn, fact := range st.local {
		if fact != nil {
			pass.ExportObjectFact(fn, fact)
		}
	}
	res := &Result{}
	for _, f := range pass.Files {
		directives := readDirectives(pass.Fset, f)
		for _, d := range f.Decls {
			switch d := d.(type) {
			case *ast.FuncDecl:
				if d.Body != nil {
					fn := pass.TypesInfo.Defs[d.Name].(*types.Func)
					st.enter(fn.Signature(), d.Body)
					st.report(res, d.Body, fn.Name(), directives)
				}
			case *ast.GenDecl:
				st.enter(nil, nil)
				st.report(res, d, "", directives)
			}
		}
	}
	return res, nil
}

// enter prepares the parameter and assignment tables of one function.
func (st *state) enter(sig *types.Signature, body ast.Node) {
	st.params = map[*types.Var]int{}
	st.assigns = map[*types.Var][]assignment{}
	if sig != nil {
		for i := 0; i < sig.Params().Len(); i++ {
			st.params[sig.Params().At(i)] = i
		}
	}
	if body == nil {
		return
	}
	info := st.pass.TypesInfo
	add := func(id *ast.Ident, a assignment) {
		if v, ok := info.ObjectOf(id).(*types.Var); ok {
			st.assigns[v] = append(st.assigns[v], a)
		}
	}
	ast.Inspect(body, func(n ast.Node) bool {
		switch n := n.(type) {
		case *ast.AssignStmt:
			for i, l := range n.Lhs {
				id, ok := ast.Unparen(l).(*ast.Ident)
				if !ok {
					continue
				}
				if len(n.Rhs) == len(n.Lhs) {
					add(id, assignment{rhs: n.Rhs[i]})
				} else {
					add(id, assignment{rhs: n.Rhs[0], index: i, multi: true})
				}
			}
		case *ast.ValueSpec:
			for i, id := range n.Names {
				switch {
				case len(n.Values) == len(n.Names):
					add(id, assignment{rhs: n.Values[i]})
				case len(n.Values) == 1:
					add(id, assignment{rhs: n.Values[0], index: i, multi: true})
				}
			}
		case *ast.RangeStmt:
			for _, e := range []ast.Expr{n.Key, n.Value} {
				if id, ok := e.(*ast.Ident); ok {
					add(id, assignment{}) // not followed
				}
			}
		}
		return true
	})
}

// keyish reports whether t carries a Firestore path.
func keyish(t types.Type) bool {
	if p, ok := t.(*types.Pointer); ok {
		t = p.Elem()
	}
	n, ok := types.Unalias(t).(*types.Named)
	if !ok || n.Obj().Pkg() == nil {
		return false
	}
	switch n.Obj().Pkg().Path() + "." + n.Obj().Name() {
	case recordPkg + ".Key", recordPkg + ".Record", recordPkg + ".DataWithID", recordPkg + ".WithID",
		dalPkg + ".CollectionRef", dalPkg + ".CollectionGroupRef":
		return true
	}
	return false
}

// factOf works out the templates a function returns and the paths it builds
// from its parameters, or nil when it has neither.
func (st *state) factOf(fd *ast.FuncDecl, fn *types.Func) *keyFact {
	sig := fn.Signature()
	results := sig.Results()
	st.enter(sig, fd.Body)
	fact := &keyFact{Results: make([][]Template, results.Len()), Uses: st.opens(fd.Body)}
	hasKey, failed := false, false
	for i := 0; i < results.Len(); i++ {
		hasKey = hasKey || keyish(results.At(i).Type())
	}
	if hasKey {
		walkReturns(fd.Body.List, nil, st.pass.TypesInfo, st.params, func(ret *ast.ReturnStmt, guard *Template) {
			for i := 0; i < results.Len() && !failed; i++ {
				if !keyish(results.At(i).Type()) {
					continue
				}
				var ts []Template
				var err error
				switch {
				case len(ret.Results) == 0:
					ts, err = st.evalVar(results.At(i))
				case len(ret.Results) == 1 && results.Len() > 1:
					ts, err = st.evalCall(ret.Results[0], i)
				default:
					e := ast.Unparen(ret.Results[i])
					if st.pass.TypesInfo.Types[e].IsNil() {
						continue
					}
					ts, err = st.evalKey(e)
				}
				failed = err != nil
				for _, t := range ts {
					if guard != nil && t.GuardParam == noGuard {
						t.GuardParam, t.Guard = guard.GuardParam, guard.Guard
					}
					fact.Results[i] = append(fact.Results[i], t)
				}
			}
		})
	}
	if failed || !hasKey {
		fact.Results = nil
	}
	if fact.Results == nil && len(fact.Uses) == 0 {
		return nil
	}
	return fact
}

// walkReturns calls f for every return statement of a function body, outside
// nested function literals, with the empty-parameter guard it sits under.
func walkReturns(list []ast.Stmt, guard *Template, info *types.Info, params map[*types.Var]int, f func(*ast.ReturnStmt, *Template)) {
	for _, s := range list {
		ast.Inspect(s, func(n ast.Node) bool {
			switch n := n.(type) {
			case *ast.FuncLit:
				return false
			case *ast.ReturnStmt:
				f(n, guard)
			case *ast.IfStmt:
				if n.Init != nil {
					walkReturns([]ast.Stmt{n.Init}, guard, info, params, f)
				}
				inner := guard
				if g := emptyGuard(n.Cond, info, params); g != nil && guard == nil {
					inner = g
				}
				walkReturns(n.Body.List, inner, info, params, f)
				if n.Else != nil {
					walkReturns([]ast.Stmt{n.Else}, guard, info, params, f)
				}
				return false
			}
			return true
		})
	}
}

// emptyGuard recognises `p == ""` (either side) for a parameter p.
func emptyGuard(cond ast.Expr, info *types.Info, params map[*types.Var]int) *Template {
	b, ok := ast.Unparen(cond).(*ast.BinaryExpr)
	if !ok || b.Op != token.EQL {
		return nil
	}
	for _, pair := range [][2]ast.Expr{{b.X, b.Y}, {b.Y, b.X}} {
		id, ok := ast.Unparen(pair[0]).(*ast.Ident)
		if !ok {
			continue
		}
		v, ok := info.Uses[id].(*types.Var)
		if !ok {
			continue
		}
		idx, isParam := params[v]
		tv := info.Types[pair[1]]
		if isParam && tv.Value != nil && tv.Value.Kind() == constant.String && constant.StringVal(tv.Value) == "" {
			return &Template{GuardParam: idx, Guard: id.Name + " is empty"}
		}
	}
	return nil
}

func (st *state) evalVar(v *types.Var) ([]Template, error) {
	if idx, ok := st.params[v]; ok {
		return []Template{{Kind: KindDocument, Segs: []Seg{{Kind: segKeyParam, Index: idx, Value: v.Name()}}, GuardParam: noGuard}}, nil
	}
	as := st.assigns[v]
	if len(as) != 1 || as[0].rhs == nil {
		return nil, fail("variable %s is assigned %d times", v.Name(), len(as))
	}
	if as[0].multi {
		return st.evalCall(as[0].rhs, as[0].index)
	}
	return st.evalKey(as[0].rhs)
}

// evalKey returns the templates of a key-typed expression. A nil key is the
// empty template (no parent).
func (st *state) evalKey(e ast.Expr) ([]Template, error) {
	e = ast.Unparen(e)
	if st.pass.TypesInfo.Types[e].IsNil() {
		return []Template{{GuardParam: noGuard}}, nil
	}
	switch e := e.(type) {
	case *ast.Ident:
		if v, ok := st.pass.TypesInfo.Uses[e].(*types.Var); ok {
			return st.evalVar(v)
		}
	case *ast.CallExpr:
		return st.evalCall(e, 0)
	}
	return nil, fail("cannot follow the key expression %s", types.ExprString(e))
}

// value returns the segment for a string or id expression.
func (st *state) value(e ast.Expr) Seg {
	e = ast.Unparen(e)
	info := st.pass.TypesInfo
	if tv := info.Types[e]; tv.Value != nil {
		if tv.Value.Kind() == constant.String {
			return Seg{Kind: segLit, Value: constant.StringVal(tv.Value)}
		}
		return Seg{Kind: segLit, Value: tv.Value.ExactString()}
	}
	switch x := e.(type) {
	case *ast.Ident:
		if v, ok := info.Uses[x].(*types.Var); ok {
			if idx, ok := st.params[v]; ok {
				return Seg{Kind: segParam, Index: idx, Value: x.Name}
			}
			if as := st.assigns[v]; len(as) == 1 && as[0].rhs != nil && !as[0].multi {
				if s := st.value(as[0].rhs); s.Kind != segWild {
					return s
				}
			}
		}
		return Seg{Kind: segWild, Value: x.Name}
	case *ast.CallExpr:
		if len(x.Args) == 1 && info.Types[x.Fun].IsType() {
			return st.value(x.Args[0])
		}
	case *ast.SelectorExpr:
		return Seg{Kind: segWild, Value: x.Sel.Name}
	}
	return Seg{Kind: segWild, Value: "id"}
}

type primitive struct {
	kind   string
	parent int // argument index of the parent key, or -1
	coll   int // argument index of the collection name, or -1 for a pass-through
	id     int // argument index of the id, or -1 for a generated id
	pass   int // argument index of a key passed through unchanged
}

var primitives = map[string]primitive{
	recordPkg + ".NewKeyWithID":               {KindDocument, -1, 0, 1, -1},
	recordPkg + ".NewKeyWithParentAndID":      {KindDocument, 0, 1, 2, -1},
	recordPkg + ".NewIncompleteKey":           {KindDocument, 2, 0, -1, -1},
	recordPkg + ".NewKeyWithFields":           {KindDocument, -1, 0, -1, -1},
	recordPkg + ".NewKeyWithOptions":          {KindDocument, -1, 0, -1, -1},
	recordPkg + ".NewRecordWithIncompleteKey": {KindGroup, -1, 0, -1, -1},
	recordPkg + ".NewRecord":                  {"", -1, -1, -1, 0},
	recordPkg + ".NewRecordWithData":          {"", -1, -1, -1, 0},
	recordPkg + ".NewDataWithID":              {"", -1, -1, -1, 1},
	recordPkg + ".NewWithID":                  {"", -1, -1, -1, 1},
	dalPkg + ".NewCollectionRef":              {KindCollection, 2, 0, -1, -1},
	dalPkg + ".NewRootCollectionRef":          {KindCollection, -1, 0, -1, -1},
	dalPkg + ".NewCollectionGroupRef":         {KindGroup, -1, 0, -1, -1},
}

func funcName(fn *types.Func) string {
	if fn.Pkg() == nil {
		return fn.Name()
	}
	return fn.Pkg().Path() + "." + fn.Name()
}

// callee returns the statically known function of a call, if any.
func (st *state) callee(call *ast.CallExpr) *types.Func {
	fn, _ := typeutil.Callee(st.pass.TypesInfo, call).(*types.Func)
	if fn == nil {
		return nil
	}
	return fn.Origin()
}

func (st *state) fact(fn *types.Func) *keyFact {
	if f, ok := st.local[fn]; ok {
		return f
	}
	f := new(keyFact)
	if st.pass.ImportObjectFact(fn, f) {
		return f
	}
	return nil
}

// evalCall returns the templates of result index of a call.
func (st *state) evalCall(e ast.Expr, index int) ([]Template, error) {
	call, ok := ast.Unparen(e).(*ast.CallExpr)
	if !ok {
		return nil, fail("cannot follow the key expression %s", types.ExprString(e))
	}
	fn := st.callee(call)
	if fn == nil {
		return nil, fail("the key comes from a dynamic call %s", types.ExprString(call.Fun))
	}
	if p, ok := primitives[funcName(fn)]; ok {
		return st.evalPrimitive(p, call)
	}
	f := st.fact(fn)
	if f == nil || index >= len(f.Results) || len(f.Results[index]) == 0 {
		return nil, fail("%s returns a key whose path is not known", fn.Name())
	}
	var out []Template
	for _, t := range f.Results[index] {
		ts, err := st.substitute(t, call)
		if err != nil {
			return nil, err
		}
		out = append(out, ts...)
	}
	return out, nil
}

func (st *state) evalPrimitive(p primitive, call *ast.CallExpr) ([]Template, error) {
	if p.pass >= 0 {
		return st.evalKey(call.Args[p.pass])
	}
	coll := st.value(call.Args[p.coll])
	if coll.Kind == segWild {
		return nil, fail("the collection name %s is not a constant", types.ExprString(call.Args[p.coll]))
	}
	if p.kind == KindGroup {
		return []Template{{Kind: KindGroup, Segs: []Seg{coll}, GuardParam: noGuard}}, nil
	}
	parents := []Template{{GuardParam: noGuard}}
	if p.parent >= 0 {
		var err error
		if parents, err = st.evalKey(call.Args[p.parent]); err != nil {
			return nil, err
		}
	}
	id := Seg{Kind: segWild, Value: "id"}
	if p.id >= 0 {
		id = st.value(call.Args[p.id])
	}
	var out []Template
	for _, parent := range parents {
		if parent.Kind == KindCollection || parent.Kind == KindGroup {
			return nil, fail("a %s reference is used as a parent key", parent.Kind)
		}
		if p.parent == 2 && p.kind == KindDocument && len(parent.Segs) == 0 {
			// NewIncompleteKey with no parent: a record placeholder, as in a
			// query's record factory; only its collection name is known.
			out = append(out, Template{Kind: KindGroup, Segs: []Seg{coll}, GuardParam: noGuard})
			continue
		}
		t := parent
		t.Kind = p.kind
		t.Segs = append(append([]Seg{}, parent.Segs...), coll)
		if p.kind == KindDocument {
			t.Segs = append(t.Segs, id)
		}
		out = append(out, t)
	}
	return out, nil
}

// args returns the arguments of a call that match the callee's parameters:
// a method expression (T.M)(recv, a, b) passes its receiver first.
func (st *state) args(call *ast.CallExpr) []ast.Expr {
	if sel, ok := ast.Unparen(call.Fun).(*ast.SelectorExpr); ok {
		if s := st.pass.TypesInfo.Selections[sel]; s != nil && s.Kind() == types.MethodExpr {
			return call.Args[1:]
		}
	}
	return call.Args
}

// substitute fills a callee's template with the arguments of a call. A
// template that comes out with an empty segment is dropped: Firestore has no
// empty ids, so that branch cannot build a path (an empty space id selects the
// spaceless branch instead).
func (st *state) substitute(t Template, call *ast.CallExpr) ([]Template, error) {
	args := st.args(call)
	out := []Template{{Kind: t.Kind, GuardParam: noGuard}}
	if t.GuardParam >= 0 {
		g := st.value(args[t.GuardParam])
		switch g.Kind {
		case segLit:
			if g.Value != "" {
				return nil, nil // the guarded branch cannot run
			}
		case segParam:
			out[0].GuardParam, out[0].Guard = g.Index, g.Value+" is empty"
		default:
			out[0].GuardParam, out[0].Guard = callerGuard, t.Guard
		}
	} else if t.GuardParam == callerGuard {
		out[0].GuardParam, out[0].Guard = callerGuard, t.Guard
	}
	for _, s := range t.Segs {
		switch s.Kind {
		case segParam:
			v := st.value(args[s.Index])
			for i := range out {
				out[i].Segs = append(out[i].Segs, v)
			}
		case segKeyParam:
			parents, err := st.evalKey(args[s.Index])
			if err != nil {
				return nil, err
			}
			var next []Template
			for _, o := range out {
				for _, p := range parents {
					n := o
					n.Segs = append(append([]Seg{}, o.Segs...), p.Segs...)
					if n.GuardParam == noGuard && p.GuardParam != noGuard {
						n.GuardParam, n.Guard = p.GuardParam, p.Guard
					}
					next = append(next, n)
				}
			}
			out = next
		default:
			for i := range out {
				out[i].Segs = append(out[i].Segs, s)
			}
		}
	}
	var kept []Template
	for _, o := range out {
		empty := false
		for i, seg := range o.Segs {
			if i%2 == 0 && seg.Kind == segWild {
				return nil, fail("the collection name passed to %s is not a constant", types.ExprString(call.Fun))
			}
			empty = empty || (seg.Kind == segLit && seg.Value == "")
		}
		if !empty {
			kept = append(kept, o)
		}
	}
	return kept, nil
}

// open reports whether a template's path still depends on the enclosing
// function's parameters in a way only its callers can settle.
func open(t Template) bool {
	for i, s := range t.Segs {
		if s.Kind == segKeyParam || (s.Kind == segParam && i%2 == 0) {
			return true
		}
	}
	return false
}

// Render returns the path of a template; id segments that are not fixed are
// shown as {name}.
func Render(t Template) string {
	parts := make([]string, len(t.Segs))
	for i, s := range t.Segs {
		if s.Kind == segLit {
			parts[i] = s.Value
		} else {
			parts[i] = "{" + s.Value + "}"
		}
	}
	return strings.Join(parts, "/")
}

// pure reports whether a template only passes a key parameter through.
func pure(t Template) bool { return len(t.Segs) == 1 && t.Segs[0].Kind == segKeyParam }

// site returns the templates a call builds: the key it returns, and the
// paths a helper builds inside from its arguments (its Uses). A call that only
// wraps a key built elsewhere (record.NewRecordWithData(rec.Key(), data), or a
// helper that only passes its key parameter on) adds nothing when that key
// cannot be followed: the constructor that built it is checked where it is
// called.
func (st *state) site(call *ast.CallExpr) ([]Template, error) {
	fn := st.callee(call)
	if fn == nil {
		return nil, nil
	}
	if p, ok := primitives[funcName(fn)]; ok {
		ts, err := st.evalCall(call, 0)
		if err != nil && p.pass >= 0 {
			return nil, nil
		}
		return ts, err
	}
	f := st.fact(fn)
	if f == nil {
		return nil, nil
	}
	var ts []Template
	add := func(t Template, eval func() ([]Template, error)) error {
		got, err := eval()
		if err != nil && pure(t) {
			return nil
		}
		ts = append(ts, got...)
		return err
	}
	for _, r := range f.Results {
		for _, t := range r {
			if err := add(t, func() ([]Template, error) { return st.substitute(t, call) }); err != nil {
				return nil, err
			}
		}
	}
	for _, u := range f.Uses {
		if err := add(u, func() ([]Template, error) { return st.substitute(u, call) }); err != nil {
			return nil, err
		}
	}
	return ts, nil
}

// opens returns the templates built in body that only callers can settle.
func (st *state) opens(body ast.Node) []Template {
	var out []Template
	seen := map[string]bool{}
	ast.Inspect(body, func(n ast.Node) bool {
		if call, ok := n.(*ast.CallExpr); ok {
			ts, _ := st.site(call)
			for _, t := range ts {
				if k := fmt.Sprint(t); open(t) && !seen[k] {
					seen[k] = true
					out = append(out, t)
				}
			}
		}
		return true
	})
	return out
}

// report records every path built inside node.
func (st *state) report(res *Result, node ast.Node, fname string, directives map[int][]string) {
	fset := st.pass.Fset
	// Bodies of `if p == ""` branches on a parameter: what they build is
	// built only when that argument is empty.
	type guardRange struct {
		*ast.BlockStmt
		Guard string
	}
	var guards []guardRange
	ast.Inspect(node, func(n ast.Node) bool {
		if is, ok := n.(*ast.IfStmt); ok {
			if g := emptyGuard(is.Cond, st.pass.TypesInfo, st.params); g != nil {
				guards = append(guards, guardRange{is.Body, g.Guard})
			}
		}
		return true
	})
	ast.Inspect(node, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		ts, err := st.site(call)
		pos := fset.Position(call.Pos())
		guard := ""
		for _, g := range guards {
			if call.Pos() >= g.Pos() && call.End() <= g.End() {
				guard = g.Guard
			}
		}
		for _, t := range ts {
			if open(t) {
				continue // in this function's Uses or Results: its callers report it
			}
			if t.Guard == "" {
				t.Guard = guard
			}
			res.Sites = append(res.Sites, Site{Path: Render(t), Kind: t.Kind, Pos: pos, Guard: t.Guard})
		}
		if err != nil {
			declared := append(directives[pos.Line], directives[pos.Line-1]...)
			if len(declared) == 0 {
				res.Unresolved = append(res.Unresolved, Unresolved{Pos: pos, Func: fname, Reason: err.Error()})
			}
			for _, p := range declared {
				res.Sites = append(res.Sites, Site{Path: p, Kind: pathKind(p), Pos: pos, Declared: true})
			}
		}
		return true
	})
}

func pathKind(p string) string {
	if strings.Count(p, "/")%2 == 1 {
		return KindDocument
	}
	return KindCollection
}

// readDirectives maps line numbers to the paths named on //firestore:path
// comments: `//firestore:path <path>... -- <reason>`.
func readDirectives(fset *token.FileSet, f *ast.File) map[int][]string {
	out := map[int][]string{}
	for _, cg := range f.Comments {
		for _, c := range cg.List {
			if rest, ok := strings.CutPrefix(c.Text, DirectivePrefix); ok {
				rest, _, _ = strings.Cut(rest, " -- ")
				line := fset.Position(c.Pos()).Line
				out[line] = append(out[line], strings.Fields(rest)...)
			}
		}
	}
	return out
}
