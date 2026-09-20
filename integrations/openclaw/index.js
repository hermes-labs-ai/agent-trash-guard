import { definePluginEntry } from "openclaw/plugin-sdk/plugin-entry";
import { registerTrashGuard } from "./entry.js";

export default definePluginEntry({
  id: "agent-trash-guard",
  name: "Agent Trash Guard",
  description: "Blocks permanent-delete exec calls and directs agents to recoverable trash.",
  register: registerTrashGuard,
});
