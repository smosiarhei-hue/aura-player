import { defineConfig } from "vite";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { yandexLabPlugin } from "./server/yandexLab";
import { mixCoachPlugin } from "./server/mixCoach";
import { whisperLabPlugin } from "./server/whisperLab";

const root = dirname(fileURLToPath(import.meta.url));

export default defineConfig({
  plugins: [yandexLabPlugin(), mixCoachPlugin(), whisperLabPlugin()],
  server: {
    // 0.0.0.0 so Cursor port-forward / Simple Browser can reach the app
    // (127.0.0.1-only often shows ERR_EMPTY_RESPONSE / connection reset).
    host: "0.0.0.0",
    port: 43187,
    strictPort: true,
  },
  build: {
    rollupOptions: {
      input: {
        main: resolve(root, "index.html"),
        lab: resolve(root, "lab.html"),
        iphone: resolve(root, "iphone.html"),
      },
    },
  },
});
