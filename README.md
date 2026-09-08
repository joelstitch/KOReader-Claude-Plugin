# AI Reading Assistant – KOReader Plugin

A KOReader plugin that brings an AI assistant to your e-reader, powered by **Anthropic Claude**, **DeepSeek**, or **MiniMax** — you choose the provider.  
Highlight any word, name, or sentence and instantly get an explanation — or ask questions about the entire book you're reading.

---

## Features

- **Highlight → Explain** — long-press any word or sentence and tap **Ask …** to get an instant explanation, translation, or biography
- **Ask …** — open a search-style dialog and ask any question about the book you're reading
- **Load Book** — let the AI read the full book so it can give accurate, context-aware answers
- **Multiple AI providers** — Anthropic Claude, DeepSeek, or MiniMax, switchable from the menu
- Works with EPUB, PDF, and most other formats supported by KOReader

---

## Requirements

- KOReader (any recent version)
- An API key for at least one provider:
  - **Anthropic** → [console.anthropic.com](https://console.anthropic.com)
  - **DeepSeek** → [platform.deepseek.com](https://platform.deepseek.com)
  - **MiniMax** → [platform.minimax.io](https://platform.minimax.io)
    (Mainland-China users: [platform.minimaxi.com](https://platform.minimaxi.com) — keys are region-bound, and CN keys require the `api.minimax.io` endpoint in `ai_api.lua` to be changed to `api.minimaxi.com`)

---

## Installation

### 1. Download

**Download the ZIP file** on this page, then extract the ZIP file.  
You should see a folder called `claude.koplugin`.

### 2. Configure your API key(s)

Open `claude_config.lua` in any text editor and paste your key(s):

```lua
return {
    api_key      = "sk-ant-...",   -- Anthropic key
    deepseek_key = "sk-...",       -- DeepSeek key
    minimax_key  = "sk-api-...",   -- MiniMax key
}
```

Leave the providers you don't use as `"YOUR_API_KEY_HERE"` — the plugin ignores placeholders.

You can also set keys directly on the device after installing (see below).

### 3. Copy to your device

Copy the entire `claude.koplugin` folder into the **plugins** folder of your device:

### 4. Restart KOReader

Restart the app. The plugin loads automatically.

---

## Choosing a provider

Open the KOReader main menu → **Tools** → **AI Assistant** → **AI Provider** and pick:

- **Anthropic Claude** (default)
- **DeepSeek**
- **MiniMax**

The menu entry, dialogs, and results display the name of the active provider. Each provider uses its own API key — `Configure API Key` edits the key of the currently selected provider.

---

## Finding the plugin on your device

Open the KOReader main menu:

![Step 1 – Open the menu](1.png)

Go to **Tools** and tap **AI Assistant**:

![Step 2 – AI Assistant in the menu](2.png)

The plugin submenu:

![Step 3 – Plugin options](3.png)

---

## How to use

### Explaining a word or sentence

1. Open a book
2. Long-press a word or drag to select a sentence
3. Tap **Ask …** in the highlight popup

The AI will explain it based on what it is:
- **A person's name** → short biography or character description
- **A place name** → description of the location
- **An unknown word** → definition and translation
- **A passage** → meaning and context explained in plain language

### Asking questions about the book

1. Open a book
2. Open the menu → **AI Assistant** → **Ask …**
3. (Optional but recommended) tap **Load Book into …** first so the AI reads the full content
4. Type your question and tap **Ask**

---

## Privacy

Your API key is stored locally on the device.  
Book text is sent to the provider you selected (Anthropic, DeepSeek, or MiniMax) only when you actively request an explanation or ask a question. Nothing is sent automatically.

---

## License

MIT License — free to use, modify, and share.
