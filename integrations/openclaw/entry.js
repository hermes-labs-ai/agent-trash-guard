import { checkCommand, reasons } from "./bridge.js";

export function registerTrashGuard(api) {
  api.on(
    "before_tool_call",
    async (event) => {
      const command = event?.params?.command;
      if (typeof command !== "string") {
        return { block: true, blockReason: reasons.UNAVAILABLE_REASON };
      }
      const decision = await checkCommand(command);
      return decision.block ? { block: true, blockReason: decision.reason } : undefined;
    },
    { matcher: ["exec"] },
  );
}
