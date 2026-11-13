# bootstrap-installer

One-time setup for building apps with the App Bootstrap Starter on **Windows**.

## Before you start

- [ ] **A GitHub account** that's a member of the **kaschmitter-apps** organization (ask the owner for an invite and accept it).
- [ ] **Your app's repository**, created from the starter template (playbook step 1). The installer asks for its address.
- [ ] **A Claude plan that includes Claude Code** (for example Pro or Max, or a Team/Enterprise seat with Claude Code). Check [claude.com/pricing](https://claude.com/pricing). Without one, everything installs but you can't use Claude in VS Code.
- [ ] **Administrator rights on your PC**, meaning you can click **Yes** on Windows permission prompts. Git and Node.js need this to install. On a company laptop without admin rights, ask IT to install **Git** and **Node.js LTS** first, then run the installer. It will skip what's already there.
- [ ] **Windows 10 or 11** and an internet connection that can reach github.com, nodejs.org, and code.visualstudio.com.

## Run it

1. Open the Start menu, type **PowerShell**, and open **Windows PowerShell**. You don't need "Run as administrator".
2. Paste this line and press Enter:

   ```powershell
   irm https://raw.githubusercontent.com/kaschmitter-apps/bootstrap-installer/main/install.ps1 | iex
   ```

3. Answer the questions. Windows may ask for permission while programs install. Click **Yes**.

## What it does

- Walks through the **Before you start** checklist above. For anything you haven't done yet, it shows step-by-step instructions and opens the right web page. You can quit at any point and run it again later.
- Installs **Git**, **Visual Studio Code**, and **Node.js** (LTS), and optionally **Python**. Anything already installed is skipped.
- Sets your name and email for Git, if they aren't set yet.
- Downloads your app's repository to `Projects\<app name>` in your user folder, installs the Claude Code extension and the project's recommended VS Code extensions, and opens it in VS Code.

It's safe to run again at any time, for example to set up a second app.
