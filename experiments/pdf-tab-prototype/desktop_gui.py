"""Batch trial window for the standalone PDF tab experiment."""
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from desktop_batch import ROOT, NOTICE, create_output, default_output


class TrialWindow:
    def __init__(self, root):
        self.root = root
        self.items = {}
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.running = False
        root.title('RiffLoop · 图片音符对照 / PDF 草稿 · 2026-10-27')
        root.geometry('1080x760')
        root.minsize(940, 700)
        style = ttk.Style(root)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10))
        style.configure('Treeview', rowheight=34)
        outer = ttk.Frame(root, padding=22)
        outer.pack(fill='both', expand=True)
        ttk.Label(outer, text='图片 → 音符对照 ｜ 矢量 PDF → GP 草稿', font=('Microsoft YaHei UI', 19, 'bold')).pack(anchor='w')
        ttk.Label(outer, text='批量选择 PDF、截图或照片，在本机处理；每份文件单独生成结果。', foreground='#46576b').pack(anchor='w', pady=(8, 4))
        ttk.Label(outer, text='图片已切换为数字与弦线识别；节奏尚未识别，暂不生成 GP。完成后请打开“查看结果 / 问题”。', foreground='#92520a').pack(anchor='w', pady=(0, 12))
        controls = ttk.Frame(outer)
        controls.pack(fill='x')
        self.add_button = ttk.Button(controls, text='添加 PDF / 截图', command=self.choose_files)
        self.add_button.pack(side='left')
        self.remove_button = ttk.Button(controls, text='移除所选', command=self.remove)
        self.remove_button.pack(side='left', padx=8)
        self.start_button = ttk.Button(controls, text='开始处理待处理文件', command=self.start)
        self.start_button.pack(side='left', padx=8)
        self.stop_button = ttk.Button(controls, text='本文件完成后停止', command=self.request_stop, state='disabled')
        self.stop_button.pack(side='left')
        output_row = ttk.Frame(outer)
        output_row.pack(fill='x', pady=12)
        self.output = tk.StringVar(value=str(default_output()))
        ttk.Label(output_row, text='结果保存到：').pack(side='left')
        ttk.Entry(output_row, textvariable=self.output, state='readonly').pack(side='left', fill='x', expand=True)
        self.output_button = ttk.Button(output_row, text='更改位置', command=self.choose_output)
        self.output_button.pack(side='left', padx=(8, 0))
        table = ttk.Frame(outer)
        table.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(table, columns=('file', 'kind', 'status'), show='headings', selectmode='extended', height=3)
        for name, label, width in [('file', '文件名', 480), ('kind', '格式', 90), ('status', '处理状态', 280)]:
            self.tree.heading(name, text=label)
            self.tree.column(name, width=width, minwidth=70)
        self.tree.pack(side='left', fill='both', expand=True)
        scroll = ttk.Scrollbar(table, orient='vertical', command=self.tree.yview)
        scroll.pack(side='right', fill='y')
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.bind('<<TreeviewSelect>>', self.show_details)
        self.tree.bind('<Double-1>', lambda _: self.open_selected('report'))
        self.detail = tk.StringVar(value='先添加文件，再点击开始处理。完成后双击一行即可查看结果。')
        detail_label = ttk.Label(outer, textvariable=self.detail, wraplength=990)
        detail_label.pack(anchor='w', pady=12)
        actions = ttk.Frame(outer)
        actions.pack(fill='x')
        for label, action in [('查看结果 / 问题', 'report'), ('打开 GP 草稿', 'draft'), ('打开原文件', 'source'), ('打开该文件结果目录', 'folder')]:
            ttk.Button(actions, text=label, command=lambda a=action: self.open_selected(a)).pack(side='left', padx=(0, 8))
        self.progress = ttk.Progressbar(outer, mode='indeterminate')
        self.progress.pack(fill='x', pady=(16, 8))
        self.status = tk.StringVar(value='就绪 · 文件不会上传')
        ttk.Label(outer, textvariable=self.status).pack(anchor='w')
        notice_label = ttk.Label(outer, text=NOTICE, wraplength=990, foreground='#92520a')
        notice_label.pack(anchor='w', pady=(12, 0))
        outer.bind('<Configure>', lambda event: [label.configure(wraplength=max(400, event.width - 44))
                                                for label in (detail_label, notice_label)])
        root.protocol('WM_DELETE_WINDOW', self.close)
        root.after(150, self.poll)

    def choose_files(self):
        self.add_files(filedialog.askopenfilenames(title='选择一份或多份 PDF / 截图', filetypes=[
            ('PDF 与图片', '*.pdf *.png *.jpg *.jpeg *.webp *.bmp *.tif *.tiff'), ('所有文件', '*.*')]))

    def add_files(self, paths):
        existing = {str(v['source']).casefold() for v in self.items.values()}
        for path in paths:
            source = Path(path).resolve()
            if str(source).casefold() in existing:
                continue
            item = self.tree.insert('', 'end', values=(source.name, source.suffix.lower(), '待处理'))
            self.items[item] = {'source': source, 'pending': True}
            existing.add(str(source).casefold())
        self.status.set(f'已加入 {len(self.items)} 份文件 · 可多选 · 文件不会上传')

    def remove(self):
        if self.running:
            return
        for item in self.tree.selection():
            del self.items[item]
            self.tree.delete(item)
        self.show_details()

    def choose_output(self):
        selected = filedialog.askdirectory(title='选择结果保存目录')
        if selected:
            self.output.set(selected)

    def start(self):
        if self.running:
            return
        jobs = [(key, item['source']) for key, item in self.items.items() if item['pending']]
        if not jobs:
            messagebox.showinfo('没有待处理文件', '请先添加文件。重新试用同一文件时，可移除后再添加。')
            return
        output_root = Path(self.output.get())
        try:
            output_root.mkdir(parents=True, exist_ok=True)
        except (OSError, ValueError) as error:
            messagebox.showerror('请检查输出位置', str(error))
            return
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.output_button):
            button.configure(state='disabled')
        self.stop_button.configure(state='normal')
        self.progress.start(15)
        threading.Thread(target=self.work, args=(jobs, output_root), daemon=True).start()

    def work(self, jobs, output_root):
        try:
            for index, (key, source) in enumerate(jobs, 1):
                if self.stop.is_set():
                    break
                self.events.put(('started', key, f'正在处理 {index}/{len(jobs)}：{source.name}'))
                folder = None
                try:
                    folder = create_output(output_root, source)
                    env = dict(os.environ, PYTHONUTF8='1', PYTHONDONTWRITEBYTECODE='1')
                    with (folder.parent / (folder.name + '.process.log')).open('w', encoding='utf-8') as log:
                        subprocess.run([sys.executable, str(ROOT / 'desktop_batch.py'), str(source), '--out', str(folder)],
                                       stdout=log, stderr=log, env=env, timeout=900, check=True,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
                    result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
                except Exception as error:
                    result = {'status': '处理失败', 'message': f'{error}；可查看结果目录旁的 process.log',
                              'folder': str(folder) if folder else None, 'draft': None}
                self.events.put(('finished', key, result))
        finally:
            self.events.put(('done', '', ''))

    def request_stop(self):
        self.stop.set()
        self.stop_button.configure(state='disabled')
        self.status.set('将在当前文件处理完后停止；剩余文件保留为待处理。')

    def poll(self):
        try:
            while True:
                event, key, payload = self.events.get_nowait()
                if event == 'started':
                    self.tree.set(key, 'status', '处理中…')
                    self.status.set(payload)
                elif event == 'finished':
                    self.items[key].update(payload, pending=False)
                    self.tree.set(key, 'status', payload['status'])
                    self.show_details()
                elif event == 'done':
                    self.running = False
                    self.progress.stop()
                    for button in (self.add_button, self.remove_button, self.start_button, self.output_button):
                        button.configure(state='normal')
                    self.stop_button.configure(state='disabled')
                    count = sum(bool(v.get('draft')) for v in self.items.values())
                    reviews = sum(v.get('status', '').startswith(('图片音符对照', '图片部分识别')) for v in self.items.values())
                    self.status.set(f'{"已停止" if self.stop.is_set() else "处理完成"} · {reviews} 份图片对照，{count} 份 PDF 草稿 · 双击文件行查看结果')
        except queue.Empty:
            pass
        self.root.after(150, self.poll)

    def show_details(self, _event=None):
        selected = self.tree.selection()
        if selected:
            item = self.items[selected[0]]
            self.detail.set(str(item['source']) + '\n' + item.get('message', '待处理。图片将生成数字与弦线对照；节奏尚未识别，不生成 GP。'))
        else:
            self.detail.set('选择文件行查看说明，双击打开结果。')

    def open_selected(self, action):
        selected = self.tree.selection()
        if not selected:
            messagebox.showinfo('选择文件', '请先选择列表中的一行。')
            return
        item = self.items[selected[0]]
        if action == 'draft' and not item.get('draft') and item.get('folder'):
            messagebox.showinfo('未生成 GP', item.get('message', '') + '\n请点击“查看结果 / 问题”。')
            return
        target = (Path(item['folder']) / 'review.html' if action == 'report' and item.get('folder')
                  else item.get(action))
        if not target or not Path(target).exists():
            messagebox.showinfo('尚无此结果', '此文件尚未生成对应结果。请查看处理状态或问题说明。')
            return
        try:
            os.startfile(str(target))
        except OSError as error:
            messagebox.showinfo('无法打开', f'请使用支持此格式的软件打开，或打开结果目录。\n{error}')

    def close(self):
        if self.running:
            self.request_stop()
            messagebox.showinfo('正在处理文件', '已停止后续队列。当前文件完成后即可关闭窗口，结果会保留。')
        else:
            self.root.destroy()


if __name__ == '__main__':
    root = tk.Tk()
    app = TrialWindow(root)
    app.add_files(sys.argv[1:])
    root.mainloop()
