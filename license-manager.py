#!/usr/bin/env python3
import json
import os
import queue
import subprocess
import threading
import traceback
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
import tkinter as tk
from tkinter import ttk, messagebox
from tkinter.scrolledtext import ScrolledText


BASE_DIR = Path("/Users/nin/Downloads/sora_license_server")
TOOLS_DIR = Path("/Users/nin/Downloads/sora_license_tools")
SERVER_SCRIPT = BASE_DIR / "server.mjs"
GENERATOR_SCRIPT = TOOLS_DIR / "generate-license.mjs"
SETTINGS_PATH = BASE_DIR / "manager-settings.json"
ERROR_LOG_PATH = BASE_DIR / "license-manager-error.log"
DEFAULT_SERVER_URL = "http://127.0.0.1:8787"


class LicenseManagerApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Sora License Manager")
        self.root.geometry("1160x760")
        self.root.minsize(980, 680)

        self.server_process = None
        self.log_queue = queue.Queue()

        self.server_url_var = tk.StringVar(value=DEFAULT_SERVER_URL)
        self.admin_token_var = tk.StringVar(value="")
        self.device_id_var = tk.StringVar(value="")
        self.days_var = tk.StringVar(value="30")

        self._build_ui()
        self._load_settings()
        self._schedule_log_pump()
        self.root.protocol("WM_DELETE_WINDOW", self._on_close)

    def _build_ui(self):
        self.root.configure(bg="#f5f3ea")

        header = tk.Frame(self.root, bg="#f5f3ea")
        header.pack(fill="x", padx=18, pady=(18, 10))

        title = tk.Label(
            header,
            text="Sora License Manager",
            bg="#f5f3ea",
            fg="#1f2937"
        )
        title.pack(anchor="w")

        subtitle = tk.Label(
            header,
            text="Generate license keys, start the local license server, and manage activate/status/revoke/reset without opening the browser admin page.",
            bg="#f5f3ea",
            fg="#6b7280",
            wraplength=980,
            justify="left"
        )
        subtitle.pack(anchor="w", pady=(6, 0))

        body = tk.Frame(self.root, bg="#f5f3ea")
        body.pack(fill="both", expand=True, padx=18, pady=(0, 18))

        left = tk.Frame(body, bg="#fffdf7", highlightbackground="#ddd4c6", highlightthickness=1)
        left.pack(side="left", fill="y", padx=(0, 10))

        right = tk.Frame(body, bg="#fffdf7", highlightbackground="#ddd4c6", highlightthickness=1)
        right.pack(side="left", fill="both", expand=True)

        self._build_left_panel(left)
        self._build_right_panel(right)

    def _build_left_panel(self, parent):
        parent.configure(width=360)
        parent.pack_propagate(False)

        pad_x = 14

        tk.Label(parent, text="Server URL", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(14, 4))
        server_entry = tk.Entry(parent, textvariable=self.server_url_var, relief="solid", bd=1)
        server_entry.pack(fill="x", padx=pad_x)

        tk.Label(parent, text="Admin Token", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(12, 4))
        admin_entry = tk.Entry(parent, textvariable=self.admin_token_var, relief="solid", bd=1)
        admin_entry.pack(fill="x", padx=pad_x)

        tk.Label(parent, text="Device ID", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(12, 4))
        self.device_entry = tk.Entry(parent, textvariable=self.device_id_var, relief="solid", bd=1)
        self.device_entry.pack(fill="x", padx=pad_x)

        tk.Label(parent, text="Days", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(12, 4))
        days_entry = tk.Entry(parent, textvariable=self.days_var, relief="solid", bd=1)
        days_entry.pack(fill="x", padx=pad_x)

        tk.Label(parent, text="License Key", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(12, 4))
        self.license_text = ScrolledText(parent, height=10, wrap="word", relief="solid", bd=1)
        self.license_text.pack(fill="both", expand=False, padx=pad_x)

        row1 = tk.Frame(parent, bg="#fffdf7")
        row1.pack(fill="x", padx=pad_x, pady=(12, 0))
        ttk.Button(row1, text="Generate Key", command=self.generate_key).pack(side="left", fill="x", expand=True)
        ttk.Button(row1, text="Copy Key", command=self.copy_license_key).pack(side="left", fill="x", expand=True, padx=(8, 0))

        row2 = tk.Frame(parent, bg="#fffdf7")
        row2.pack(fill="x", padx=pad_x, pady=(10, 0))
        ttk.Button(row2, text="Start Server", command=self.start_server).pack(side="left", fill="x", expand=True)
        ttk.Button(row2, text="Stop Server", command=self.stop_server).pack(side="left", fill="x", expand=True, padx=(8, 0))

        row3 = tk.Frame(parent, bg="#fffdf7")
        row3.pack(fill="x", padx=pad_x, pady=(10, 0))
        ttk.Button(row3, text="Health", command=self.check_health).pack(side="left", fill="x", expand=True)
        ttk.Button(row3, text="Open Admin", command=self.open_admin_page).pack(side="left", fill="x", expand=True, padx=(8, 0))

        row4 = tk.Frame(parent, bg="#fffdf7")
        row4.pack(fill="x", padx=pad_x, pady=(16, 0))
        ttk.Button(row4, text="Activate", command=self.activate_license).pack(side="left", fill="x", expand=True)
        ttk.Button(row4, text="Validate", command=self.validate_license).pack(side="left", fill="x", expand=True, padx=(8, 0))

        row5 = tk.Frame(parent, bg="#fffdf7")
        row5.pack(fill="x", padx=pad_x, pady=(10, 0))
        ttk.Button(row5, text="Status", command=self.status_license).pack(side="left", fill="x", expand=True)
        ttk.Button(row5, text="List All", command=self.list_licenses).pack(side="left", fill="x", expand=True, padx=(8, 0))

        row6 = tk.Frame(parent, bg="#fffdf7")
        row6.pack(fill="x", padx=pad_x, pady=(10, 0))
        ttk.Button(row6, text="Revoke", command=self.revoke_license).pack(side="left", fill="x", expand=True)
        ttk.Button(row6, text="Unrevoke", command=self.unrevoke_license).pack(side="left", fill="x", expand=True, padx=(8, 0))

        row7 = tk.Frame(parent, bg="#fffdf7")
        row7.pack(fill="x", padx=pad_x, pady=(10, 0))
        ttk.Button(row7, text="Reset", command=self.reset_license).pack(side="left", fill="x", expand=True)
        ttk.Button(row7, text="Save Settings", command=self.save_settings).pack(side="left", fill="x", expand=True, padx=(8, 0))

        note = tk.Label(
            parent,
            text="Tip: put the Device ID from the extension popup here, then click Generate Key. You can manage the same key with the buttons above.",
            bg="#fffdf7",
            fg="#6b7280",
            wraplength=320,
            justify="left"
        )
        note.pack(anchor="w", padx=pad_x, pady=(14, 14))

    def _build_right_panel(self, parent):
        pad_x = 14

        tk.Label(parent, text="Status / Result", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(14, 4))
        self.result_text = ScrolledText(parent, height=18, wrap="word", relief="solid", bd=1)
        self.result_text.pack(fill="both", expand=True, padx=pad_x, pady=(0, 10))

        tk.Label(parent, text="Server Log", bg="#fffdf7", fg="#6b7280").pack(anchor="w", padx=pad_x, pady=(0, 4))
        self.log_text = ScrolledText(parent, height=12, wrap="word", relief="solid", bd=1)
        self.log_text.pack(fill="both", expand=True, padx=pad_x, pady=(0, 14))

    def _load_settings(self):
        try:
            data = json.loads(SETTINGS_PATH.read_text())
        except Exception:
            data = {}
        self.server_url_var.set(str(data.get("server_url") or DEFAULT_SERVER_URL))
        self.admin_token_var.set(str(data.get("admin_token") or ""))
        self.device_id_var.set(str(data.get("device_id") or ""))
        self.days_var.set(str(data.get("days") or "30"))

    def save_settings(self):
        data = {
            "server_url": self.server_url_var.get().strip() or DEFAULT_SERVER_URL,
            "admin_token": self.admin_token_var.get().strip(),
            "device_id": self.device_id_var.get().strip(),
            "days": self.days_var.get().strip() or "30"
        }
        SETTINGS_PATH.write_text(json.dumps(data, indent=2))
        self.log("Saved settings.")

    def _set_result(self, text):
        self.result_text.delete("1.0", tk.END)
        self.result_text.insert(tk.END, text)
        self.result_text.see(tk.END)

    def log(self, text):
        self.log_text.insert(tk.END, f"{text}\n")
        self.log_text.see(tk.END)

    def _schedule_log_pump(self):
        try:
            while True:
                line = self.log_queue.get_nowait()
                self.log(line)
        except queue.Empty:
            pass
        self.root.after(200, self._schedule_log_pump)

    def _get_license_key(self):
        return self.license_text.get("1.0", tk.END).strip()

    def _set_license_key(self, value):
        self.license_text.delete("1.0", tk.END)
        self.license_text.insert(tk.END, value)

    def _headers(self, include_json=False):
        headers = {}
        token = self.admin_token_var.get().strip()
        if token:
            headers["X-Admin-Token"] = token
        if include_json:
            headers["Content-Type"] = "application/json"
        return headers

    def _server_url(self):
        return (self.server_url_var.get().strip() or DEFAULT_SERVER_URL).rstrip("/")

    def _request(self, method, path, payload=None):
        url = f"{self._server_url()}{path}"
        data = None
        headers = self._headers(include_json=payload is not None)
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
        req = urllib.request.Request(url, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=10) as response:
                text = response.read().decode("utf-8")
                return json.loads(text or "{}")
        except urllib.error.HTTPError as error:
            text = error.read().decode("utf-8", errors="replace")
            try:
                data = json.loads(text or "{}")
                raise RuntimeError(data.get("message") or f"HTTP {error.code}")
            except json.JSONDecodeError:
                raise RuntimeError(text or f"HTTP {error.code}")
        except urllib.error.URLError as error:
            raise RuntimeError(str(error.reason))

    def _run_in_thread(self, fn):
        threading.Thread(target=fn, daemon=True).start()

    def generate_key(self):
        def task():
            device_id = self.device_id_var.get().strip().upper()
            days = self.days_var.get().strip() or "30"
            if not device_id:
                self.root.after(0, lambda: messagebox.showerror("Missing Device ID", "Please enter a Device ID first."))
                return
            try:
                result = subprocess.run(
                    ["node", str(GENERATOR_SCRIPT), "--device", device_id, "--days", days],
                    capture_output=True,
                    text=True,
                    check=True
                )
                key = result.stdout.strip()
                self.root.after(0, lambda: self._set_license_key(key))
                self.root.after(0, lambda: self._set_result(key))
                self.log_queue.put("Generated new license key.")
            except subprocess.CalledProcessError as error:
                self.root.after(0, lambda: self._set_result(error.stderr or error.stdout or "Could not generate key."))
                self.log_queue.put("Generate key failed.")

        self._run_in_thread(task)

    def copy_license_key(self):
        key = self._get_license_key()
        if not key:
            messagebox.showerror("No License Key", "There is no license key to copy yet.")
            return
        self.root.clipboard_clear()
        self.root.clipboard_append(key)
        self.log("Copied license key.")

    def start_server(self):
        if self.server_process and self.server_process.poll() is None:
            self.log("Server is already running.")
            return

        self.save_settings()
        env = os.environ.copy()
        admin_token = self.admin_token_var.get().strip()
        if admin_token:
            env["ADMIN_TOKEN"] = admin_token
        elif "ADMIN_TOKEN" in env:
            env.pop("ADMIN_TOKEN", None)

        try:
            self.server_process = subprocess.Popen(
                ["node", str(SERVER_SCRIPT)],
                cwd=str(BASE_DIR),
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True
            )
        except Exception as error:
            self.log(f"Could not start server: {error}")
            return

        self.log("Starting local license server...")
        threading.Thread(target=self._read_server_output, daemon=True).start()

    def _read_server_output(self):
        if not self.server_process or not self.server_process.stdout:
            return
        for line in self.server_process.stdout:
            self.log_queue.put(line.rstrip())

    def stop_server(self):
        if not self.server_process or self.server_process.poll() is not None:
            self.log("Server is not running.")
            return
        self.server_process.terminate()
        self.log("Stopped local license server.")

    def check_health(self):
        def task():
            try:
                data = self._request("GET", "/health")
                text = json.dumps(data, indent=2)
                self.root.after(0, lambda: self._set_result(text))
                self.log_queue.put("Health check succeeded.")
            except Exception as error:
                self.root.after(0, lambda: self._set_result(str(error)))
                self.log_queue.put("Health check failed.")

        self._run_in_thread(task)

    def open_admin_page(self):
        import webbrowser
        webbrowser.open(f"{self._server_url()}/admin")
        self.log("Opened admin page in browser.")

    def _require_key(self):
        key = self._get_license_key()
        if not key:
            messagebox.showerror("No License Key", "Paste or generate a license key first.")
            return ""
        return key

    def _require_device_id(self):
        device_id = self.device_id_var.get().strip().upper()
        if not device_id:
            messagebox.showerror("No Device ID", "Please enter the Device ID first.")
            return ""
        return device_id

    def _post_license_action(self, path, require_device=False):
        key = self._require_key()
        if not key:
            return
        device_id = self._require_device_id() if require_device else ""
        if require_device and not device_id:
            return

        def task():
            payload = {"licenseKey": key}
            if require_device:
                payload["deviceId"] = device_id
            try:
                data = self._request("POST", path, payload)
                text = json.dumps(data, indent=2)
                self.root.after(0, lambda: self._set_result(text))
                self.log_queue.put(f"{path} succeeded.")
            except Exception as error:
                self.root.after(0, lambda: self._set_result(str(error)))
                self.log_queue.put(f"{path} failed.")

        self._run_in_thread(task)

    def activate_license(self):
        self._post_license_action("/api/activate", require_device=True)

    def validate_license(self):
        self._post_license_action("/api/validate", require_device=True)

    def status_license(self):
        key = self._require_key()
        if not key:
            return

        def task():
            try:
                query = urllib.parse.quote(key, safe="")
                data = self._request("GET", f"/api/admin/status?licenseKey={query}")
                text = json.dumps(data, indent=2)
                self.root.after(0, lambda: self._set_result(text))
                self.log_queue.put("Status loaded.")
            except Exception as error:
                self.root.after(0, lambda: self._set_result(str(error)))
                self.log_queue.put("Status failed.")

        self._run_in_thread(task)

    def list_licenses(self):
        def task():
            try:
                data = self._request("GET", "/api/admin/list")
                text = json.dumps(data, indent=2)
                self.root.after(0, lambda: self._set_result(text))
                self.log_queue.put("Loaded license list.")
            except Exception as error:
                self.root.after(0, lambda: self._set_result(str(error)))
                self.log_queue.put("List failed.")

        self._run_in_thread(task)

    def revoke_license(self):
        self._post_license_action("/api/admin/revoke", require_device=False)

    def unrevoke_license(self):
        self._post_license_action("/api/admin/unrevoke", require_device=False)

    def reset_license(self):
        self._post_license_action("/api/admin/reset", require_device=False)

    def _on_close(self):
        self.save_settings()
        if self.server_process and self.server_process.poll() is None:
            self.server_process.terminate()
        self.root.destroy()


def main():
    try:
        root = tk.Tk()
        app = LicenseManagerApp(root)
        root.mainloop()
    except Exception:
        trace = traceback.format_exc()
        ERROR_LOG_PATH.write_text(trace)
        print(trace)
        print(f"\nSaved error log to: {ERROR_LOG_PATH}")
        raise


if __name__ == "__main__":
    main()
