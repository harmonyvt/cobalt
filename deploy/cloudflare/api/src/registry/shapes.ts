// Response shapes of the routes the generated clients use (APP-API-CONTRACT.md 33.13). They describe the JSON the
// handlers already answer; they are never used to build or rewrite a reply. test/gen.test.ts checks real answers against
// them, and `npm run gen` turns them into openapi.json and the Swift client's types.
//
// `x-swift` names the app's own Swift type for a named shape (CobaltKit already decodes it), so the generated client
// reuses it instead of writing a second one. In a list such a type is decoded one row at a time (`Lossy`): a single odd
// row never hides the others.
import * as z from "zod";

const Ms = z.number().int().describe("milliseconds since the epoch");

// ---- GET /share/collections (section 26) -----------------------------------------------------------------------------

export const ShareCollectionShape = z
    .object({
        id: z.string(),
        name: z.string(),
        created_at: Ms,
        updated_at: Ms,
        set_ids: z.array(z.string()).describe("the collection's live gallery links, most recently added first"),
    })
    .meta({ id: "ShareCollection", "x-swift": "ShareCollection" });

export const ShareCollectionsListShape = z.object({
    status: z.literal("success"),
    collections: z.array(ShareCollectionShape).describe("most recently changed first"),
});

// ---- GET /library (sections 5, 13, 16.5, 18.3) -----------------------------------------------------------------------

const FileShape = z.looseObject({ id: z.string(), url: z.string().nullable() }).describe("one file (its fields depend on ?v)");

// One post. Its fields grow with ?v=2 (visibility) and ?v=3 (kind, item counts, a gallery's items and made files).
export const LibraryPostShape = z
    .looseObject({
        id: z.string().describe("the post key"),
        service: z.string().nullable(),
        link: z.string().nullable(),
        title: z.string().nullable(),
        custom_title: z.string().nullable(),
        duration: z.number().nullable(),
        width: z.number().nullable(),
        height: z.number().nullable(),
        poster_url: z.string().nullable(),
        public_url: z.string().nullable(),
        created_at: Ms,
        session: z
            .object({ id: z.string(), status: z.string(), expires_at: Ms, source_url: z.string() })
            .nullable()
            .describe("the post's open studio session, if any"),
        files: z.array(FileShape),
        visibility: z.enum(["public", "private"]).optional().describe("v=2 and up"),
    })
    .meta({ id: "LibraryPost", "x-swift": "LibraryPost" });

export const LibraryIndexShape = z.object({
    status: z.literal("success"),
    posts: z.array(LibraryPostShape).describe("newest first"),
    // always sent today; optional because clients still read servers from before sections 13 and 16
    counts: z.object({ posts: z.number().int(), files: z.number().int() }).optional().describe("over the whole library, not the page"),
    usage: z.object({ public_bytes: z.number().int(), private_bytes: z.number().int() }).optional().describe("bytes stored, public and private"),
    next: z.string().nullable().describe("the cursor of the next page, null on the last"),
});
