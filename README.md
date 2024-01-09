# 📦boxxer
Odin game code hotloading host.

Based on this article by Karl Zylinski: https://zylinski.se/posts/hot-reload-gameplay-code/

### Example folder structure:
```
Project/
├─ src/
│  ├─ game.odin
├─ build/
│  ├─ boxxer.exe
│  ├─ game.dll
```

### Example usage:
```bash
cd build
boxxer.exe -src:C:\code\Project\src -pkg:src -dll:game
```

### boxxer takes 3 arguments:
* `-src:` The code directory that [efsw](https://github.com/dch-GH/efsw-odin) should watch for file saves. Saving files in your game package directory (including subfolders) will trigger a hotload automatically.
* `-pkg:` The package folder name of your odin code. In the example above it would be `src` with how I've laid out my project. It would be whatever the root folder for your game code is. Needed for telling Odin how to compile your game package.
* `-dll:` The name of your game's output dll. This is what boxxer will tell the Odin compiler what to name your game package dll.
