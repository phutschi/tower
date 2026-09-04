import js from "@eslint/js";
import tseslint from "typescript-eslint";

export default tseslint.config(
  { ignores: ["dist/**", "node_modules/**", ".worktrees/**"] },
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ["src/**/*.ts", "src/**/*.tsx"],
    rules: {
      "@typescript-eslint/no-non-null-assertion": "error",
      "@typescript-eslint/consistent-type-imports": "error",
      "no-restricted-globals": [
        "error",
        { name: "Bun", message: "src/ runs on Node too; use node:* APIs." },
      ],
    },
  },
  {
    files: ["src/**/*.test.ts", "src/**/*.test.tsx"],
    rules: { "no-restricted-globals": "off" },
  },
);
