import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
  server: {
    proxy: {
      "/oauth": "https://notedude2-mcp.web.app",
      "/mcp": "https://notedude2-mcp.web.app",
    },
  },
});
