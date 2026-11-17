import { getExt } from "./lib/browser";
import { SITES, normalizeSites, type SiteId } from "./lib/view";

const ext = getExt();
if (ext) void init(ext);

async function init(api: NonNullable<ReturnType<typeof getExt>>) {
    const list = document.querySelector("#sites")!;
    const current = normalizeSites(await api.runtime.sendMessage({ type: "get-sites" }));
    for (const site of SITES) {
        const li = document.createElement("li");
        const label = document.createElement("label");
        const input = document.createElement("input");
        input.type = "checkbox";
        input.checked = current[site.id];
        input.addEventListener("change", () => {
            current[site.id] = input.checked;
            void api.runtime.sendMessage({ type: "set-sites", sites: current });
        });
        label.append(input, document.createTextNode(site.label));
        li.append(label);
        list.append(li);
    }
}

export type { SiteId };
