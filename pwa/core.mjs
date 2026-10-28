export const MAX_BYTES = 19 * 1024 * 1024;
export function audioType(type) {
  return type.split(";")[0].trim().toLowerCase();
}
export function extension(type) {
  return audioType(type) === "audio/mp4" ? "m4a" : "webm";
}
export function toolResult(message) {
  if (message.error)
    throw new Error(message.error.message || "MCP request failed.");
  const result = message.result;
  if (result?.isError)
    throw new Error(
      result.content?.find((c) => c.type === "text")?.text ||
        "NoteDude could not save this recording.",
    );
  if (
    !result?.structuredContent?.note_id ||
    result.structuredContent.status !== "ready"
  )
    throw new Error("NoteDude did not confirm this recording.");
  return result.structuredContent;
}
export function base64url(bytes) {
  return btoa(String.fromCharCode(...bytes))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
}
