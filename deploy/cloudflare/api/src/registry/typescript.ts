// The model's TypeScript cheat sheet, generated from the ops' zod schemas (APP-API-CONTRACT.md 33.3). Handles the zod
// subset the ops use: objects, arrays, strings, numbers, booleans, enums, literals, unions, optional, nullable, defaults.
// Field comments come from `.describe()`. A schema registered with `.meta({ id })` prints as a named type declared once
// at the top; `.meta({ ts })` prints that text verbatim.
import * as z from "zod";
import type { AiFlags, Op } from "./op";
import type { Registry } from "./registry";

type Meta = { id?: string; ts?: string; description?: string };
const metaOf = (s: z.ZodType): Meta => (z.globalRegistry.get(s) as Meta | undefined) ?? {};
const def = (s: z.ZodType): any => (s as any)._zod.def;

// The description of a field, wherever it sits (on the optional wrapper or the type inside it).
function describeOf(s: z.ZodType): string | undefined {
    for (let cur: z.ZodType | undefined = s; cur; ) {
        const m = metaOf(cur);
        if (m.description) return m.description;
        const d = def(cur);
        cur = d.type === "optional" || d.type === "nullable" || d.type === "default" || d.type === "pipe" ? (d.innerType ?? d.in) : undefined;
    }
    return undefined;
}

const isOptional = (s: z.ZodType): boolean => {
    const t = def(s).type;
    return t === "optional" || t === "default";
};

class Printer {
    named = new Map<string, string>();
    order: string[] = [];

    type(s: z.ZodType, indent = ""): string {
        const m = metaOf(s);
        if (m.ts) return m.ts;
        if (m.id) {
            if (!this.named.has(m.id)) {
                this.named.set(m.id, ""); // reserve against cycles
                this.named.set(m.id, this.body(s, ""));
                this.order.push(m.id);
            }
            return m.id;
        }
        return this.body(s, indent);
    }

    body(s: z.ZodType, indent: string): string {
        const d = def(s);
        switch (d.type) {
            case "string":
                return "string";
            case "number":
            case "int":
                return "number";
            case "boolean":
                return "boolean";
            case "null":
                return "null";
            case "unknown":
            case "any":
                return "unknown";
            case "literal":
                return d.values.map((v: unknown) => JSON.stringify(v)).join(" | ");
            case "enum":
                return Object.values(d.entries)
                    .map((v) => JSON.stringify(v))
                    .join(" | ");
            case "array": {
                const inner = this.type(d.element, indent);
                return /[|&]/.test(inner) && !/^[({]/.test(inner) ? `(${inner})[]` : `${inner}[]`;
            }
            case "intersection":
                return `${this.type(d.left, indent)} & ${this.type(d.right, indent)}`;
            case "union":
                return d.options.map((o: z.ZodType) => this.type(o, indent)).join(" | ");
            case "optional":
            case "default":
                return this.type(d.innerType, indent);
            case "nullable":
                return `${this.type(d.innerType, indent)} | null`;
            case "pipe":
                // a preprocess (transform -> schema) prints as the schema it ends in
                return this.type(def(d.in).type === "transform" ? d.out : d.in, indent);
            case "record":
                return `Record<string, ${this.type(d.valueType, indent)}>`;
            case "object":
                return this.object(d.shape, indent);
            default:
                return "unknown";
        }
    }

    // One line per field when any field has a comment, else inline.
    object(shape: Record<string, z.ZodType>, indent: string): string {
        const keys = Object.keys(shape);
        if (keys.length === 0) return "{}";
        const fields = keys.map((k) => {
            const f = shape[k]!;
            return { k, opt: isOptional(f), t: this.type(f, `${indent}  `), doc: describeOf(f) };
        });
        if (!fields.some((f) => f.doc)) return `{ ${fields.map((f) => `${f.k}${f.opt ? "?" : ""}: ${f.t}`).join("; ")} }`;
        const lines = fields.map((f) => `${indent}  ${f.k}${f.opt ? "?" : ""}: ${f.t};${f.doc ? ` // ${f.doc}` : ""}`);
        return `{\n${lines.join("\n")}\n${indent}}`;
    }
}

// The call's parameter list: the positional params, then the rest as one optional options object.
function signature(p: Printer, op: Op, indent: string): string {
    const d = def(op.input);
    const shape: Record<string, z.ZodType> = d.type === "object" ? d.shape : {};
    const params = op.ai.params ?? [];
    const parts = params.map((name) => {
        const f = shape[name];
        if (!f) throw new Error(`op ${op.name}: param ${name} is not in its input`);
        return `${name}${isOptional(f) ? "?" : ""}: ${p.type(f, indent)}`;
    });
    const rest = Object.keys(shape).filter((k) => !params.includes(k));
    if (op.ai.options && rest.length > 0) {
        const restShape = Object.fromEntries(rest.map((k) => [k, shape[k]!]));
        const allOptional = rest.every((k) => isOptional(shape[k]!));
        parts.push(`opts${allOptional ? "?" : ""}: ${p.object(restShape, indent)}`);
    }
    return parts.join(", ");
}

type Tree = { calls: { name: string; op: Op }[]; spaces: Map<string, Tree> };

// `declare const cobalt: {...}` for the ops the model may call, grouped by their dotted call names, with the named
// types they use declared first.
export function toolTypesFor(registry: Registry, flags: AiFlags): string {
    const p = new Printer();
    const root: Tree = { calls: [], spaces: new Map() };
    for (const op of registry.toolsFor("chat", flags)) {
        const parts = op.callName.split(".");
        let t = root;
        for (const ns of parts.slice(0, -1)) {
            if (!t.spaces.has(ns)) t.spaces.set(ns, { calls: [], spaces: new Map() });
            t = t.spaces.get(ns)!;
        }
        t.calls.push({ name: parts[parts.length - 1]!, op });
    }
    const render = (t: Tree, indent: string): string[] => {
        const lines: string[] = [];
        for (const [ns, sub] of t.spaces) {
            lines.push(`${indent}${ns}: {`, ...render(sub, `${indent}  `), `${indent}};`);
        }
        for (const { name, op } of t.calls) {
            for (const l of op.ai.summary.split("\n")) lines.push(`${indent}// ${l}`);
            if (op.ai.tier === "ask") lines.push(`${indent}// Asks Harmony first: returns { pending_confirm } and nothing runs until they tap yes.`);
            const out = op.output ? p.type(op.output, indent) : "unknown";
            lines.push(`${indent}${name}(${signature(p, op, indent)}): Promise<${out}>;`);
        }
        return lines;
    };
    const body = render(root, "  ");
    const named = p.order.map((id) => `type ${id} = ${p.named.get(id)};`);
    return [...named, "declare const cobalt: {", ...body, "};"].join("\n");
}

// The input for a chat call: the op's own mapping, or the positional params plus a trailing options object.
export function argsToInput(op: Op, args: unknown[]): unknown {
    if (op.ai.args) return op.ai.args(args);
    const params = op.ai.params ?? [];
    const input: Record<string, unknown> = {};
    params.forEach((name, i) => {
        if (args[i] !== undefined) input[name] = args[i];
    });
    const opts = args[params.length];
    if (op.ai.options && opts && typeof opts === "object" && !Array.isArray(opts)) {
        for (const [k, v] of Object.entries(opts)) if (!(k in input)) input[k] = v;
    }
    return input;
}
