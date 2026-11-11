// The MCP app's tools (MCP-APP-CONTRACT.md section 4): narrow tools that return a readable text answer plus
// `structuredContent`, each tied to a widget view. They compose the registry's chat ops through `ctx.call`.
import type { AppTool } from "./types";
import { showEdit } from "./tools/edit";
import { jobStatus } from "./tools/job";
import { createShareLink, listCollections, listShareLinks } from "./tools/links";
import { showPost } from "./tools/post";
import { saveLink } from "./tools/save";
import { searchLibrary } from "./tools/search";
import { uploadFiles } from "./tools/upload";
import { convertToWebp } from "./tools/webp";

export const APP_TOOLS: AppTool[] = [searchLibrary, showPost, showEdit, listCollections, listShareLinks, convertToWebp, uploadFiles, createShareLink, saveLink, jobStatus];
