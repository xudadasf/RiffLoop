"""Batch trial window for the standalone PDF tab experiment."""
import json
import os
from datetime import datetime
from pathlib import Path
import queue
import subprocess
import sys
import threading
import tkinter as tk
from tkinter import filedialog, messagebox, ttk
from desktop_batch import ROOT, create_output, default_output


def recover_draft_after_error(folder, error, *, source=None, sources=None):
    """Keep a completed draft only when its own readback record proves it."""
    if not folder:
        return None
    try:
        folder = Path(folder).resolve()
        draft = folder/'score.draft.gp'
        review = json.loads((folder/'score.draft.gp.review.json').read_text(encoding='utf-8'))
        if not draft.is_file() or draft.stat().st_size == 0 or not str(review.get('roundtrip', '')).startswith('passed'):
            return None
        if sources is not None:
            parts = review.get('join_parts')
            if not isinstance(parts,list) or [Path(p['source']).resolve() for p in parts] != [Path(s).resolve() for s in sources]:
                return None
            result = {'folder':str(folder), 'draft':str(draft), 'status':'拼接草稿已生成 · 后处理异常', 'message':''}
        else:
            result = json.loads((folder/'result.json').read_text(encoding='utf-8'))
            if not isinstance(result,dict) or Path(result['folder']).resolve() != folder or \
               Path(result['source']).resolve() != Path(source).resolve() or \
               Path(result['draft']).resolve() != draft or '草稿已生成' not in result['status']:
                return None
            result['status'] = '草稿已生成 · 后处理异常'
        result['message'] = result.get('message','') + f' GP 已生成并通过读回检查，但后处理异常：{error}；请查看结果目录旁的日志。'
        return result
    except (OSError, ValueError, TypeError, KeyError, AttributeError):
        return None


class TrialWindow:
    def __init__(self, root):
        self.root = root
        self.items = {}
        self.events = queue.Queue()
        self.stop = threading.Event()
        self.running = False
        self.cleaning = False
        root.title('RiffLoop · 图片 / PDF 草稿 · 支持拼接与空白分隔')
        scale = max(1.0, float(root.tk.call('tk', 'scaling')) / (96 / 72))
        min_width = min(round(940 * scale), root.winfo_screenwidth() - 40)
        min_height = min(round(760 * scale), root.winfo_screenheight() - 80)
        root.minsize(min_width, min_height)
        width = min(max(1120, min_width), root.winfo_screenwidth() - 40)
        height = min(max(800, min_height), root.winfo_screenheight() - 80)
        root.geometry(f'{width}x{height}')
        root.configure(background='#f2f5fa')
        style = ttk.Style(root)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10), foreground='#25324a')
        style.configure('TFrame', background='#f2f5fa')
        style.configure('TLabel', background='#f2f5fa')
        style.configure('Card.TFrame', background='#ffffff')
        style.configure('Card.TLabel', background='#ffffff', foreground='#25324a')
        style.configure('Muted.TLabel', background='#ffffff', foreground='#66758b', font=('Microsoft YaHei UI', 9))
        style.configure('Section.TLabel', background='#ffffff', foreground='#182640', font=('Microsoft YaHei UI', 11, 'bold'))
        style.configure('TButton', padding=(12, 7), background='#ffffff', bordercolor='#d6deea',
                        foreground='#31425d', focusthickness=1, focuscolor='#8aa6fa')
        style.map('TButton', background=[('disabled', '#f2f4f8'), ('active', '#eef3ff')],
                  foreground=[('disabled', '#a0aaba')])
        style.configure('Compact.TButton', padding=(10, 4))
        style.configure('Primary.TButton', padding=(14, 8), background='#375fe4', bordercolor='#375fe4',
                        foreground='#ffffff', font=('Microsoft YaHei UI', 10, 'bold'))
        style.map('Primary.TButton', background=[('disabled', '#cbd5ee'), ('active', '#284bc4')],
                  foreground=[('disabled', '#ffffff')])
        style.configure('Treeview', rowheight=36, background='#ffffff', fieldbackground='#ffffff',
                        bordercolor='#e2e8f1', lightcolor='#e2e8f1', darkcolor='#e2e8f1')
        style.configure('Treeview.Heading', background='#f5f7fb', foreground='#63738b',
                        font=('Microsoft YaHei UI', 9, 'bold'), padding=(8, 8), relief='flat')
        style.map('Treeview', background=[('selected', '#e4edff')], foreground=[('selected', '#173b88')])
        style.configure('Horizontal.TProgressbar', background='#5279ef', troughcolor='#e9eef7', borderwidth=0)

        outer = ttk.Frame(root, padding=(22, 18, 22, 16))
        outer.pack(fill='both', expand=True)
        header = ttk.Frame(outer)
        header.pack(fill='x', pady=(0, 16))
        ttk.Label(header, text='RiffLoop  /  谱面工作台', background='#f2f5fa', foreground='#5572b6',
                  font=('Microsoft YaHei UI', 9, 'bold')).pack(anchor='w')
        ttk.Label(header, text='图片与 PDF 转 GP', background='#f2f5fa', foreground='#15233d',
                  font=('Microsoft YaHei UI', 21, 'bold')).pack(anchor='w', pady=(2, 0))
        ttk.Label(header, text='把谱面整理成可编辑的草稿，再到 Guitar Pro 中完善。',
                  background='#f2f5fa', foreground='#6c7a90', font=('Microsoft YaHei UI', 9)).pack(anchor='w', pady=(2, 0))

        body = ttk.Frame(outer)
        body.pack(fill='both', expand=True)
        body.columnconfigure(0, weight=1, uniform='body')
        body.columnconfigure(1, weight=0, minsize=300)
        body.rowconfigure(0, weight=1)
        workspace = ttk.Frame(body, style='Card.TFrame', padding=18)
        workspace.grid(row=0, column=0, sticky='nsew', padx=(0, 12))
        sidebar_frame = ttk.Frame(body, style='Card.TFrame', width=300)
        sidebar_frame.grid(row=0, column=1, sticky='nsew')
        sidebar_frame.grid_propagate(False)
        sidebar_frame.rowconfigure(0, weight=1)
        sidebar_frame.columnconfigure(0, weight=1)
        sidebar_canvas = tk.Canvas(sidebar_frame, background='#ffffff', highlightthickness=0, width=280)
        sidebar_canvas.grid(row=0, column=0, sticky='nsew')
        sidebar_scroll = ttk.Scrollbar(sidebar_frame, orient='vertical', command=sidebar_canvas.yview)
        sidebar_scroll.grid(row=0, column=1, sticky='ns')
        def update_sidebar_scroll(first, last):
            sidebar_scroll.set(first, last)
            if float(first) <= 0 and float(last) >= 1:
                sidebar_scroll.grid_remove()
            else:
                sidebar_scroll.grid()
        sidebar_canvas.configure(yscrollcommand=update_sidebar_scroll)
        sidebar = ttk.Frame(sidebar_canvas, style='Card.TFrame', padding=16)
        sidebar_window = sidebar_canvas.create_window(0, 0, anchor='nw', window=sidebar)
        sidebar.bind('<Configure>', lambda _event: sidebar_canvas.configure(scrollregion=sidebar_canvas.bbox('all')))
        sidebar_canvas.bind('<Configure>', lambda event: sidebar_canvas.itemconfigure(sidebar_window, width=event.width))

        title_row = ttk.Frame(workspace, style='Card.TFrame')
        title_row.pack(fill='x')
        ttk.Label(title_row, text='待处理文件', style='Section.TLabel').pack(side='left')
        ttk.Label(title_row, text='可按住 Ctrl 多选', style='Muted.TLabel').pack(side='right')
        ttk.Label(workspace, text='添加 PDF、截图或照片；多份文件也可以拼接。', style='Muted.TLabel').pack(anchor='w', pady=(4, 10))
        controls = ttk.Frame(workspace, style='Card.TFrame')
        controls.pack(fill='x', pady=(0, 10))
        self.add_button = ttk.Button(controls, text='＋ 添加文件', command=self.choose_files)
        self.add_button.pack(side='left', padx=(0, 8))
        self.remove_button = ttk.Button(controls, text='移除所选', command=self.remove)
        self.remove_button.pack(side='left', padx=(0, 8))
        self.join_button = ttk.Button(controls, text='拼接所选文件…', command=self.join_selected)
        self.join_button.pack(side='left')
        table = ttk.Frame(workspace, style='Card.TFrame')
        table.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(table, columns=('file', 'kind', 'status'), show='headings', selectmode='extended', height=1)
        for name, label, width in [('file', '文件名', 310), ('kind', '格式', 80), ('status', '处理状态', 180)]:
            self.tree.heading(name, text=label, anchor='w')
            self.tree.column(name, width=width, minwidth=65, stretch=name != 'kind')
        self.tree.pack(side='left', fill='both', expand=True)
        scroll = ttk.Scrollbar(table, orient='vertical', command=self.tree.yview)
        scroll.pack(side='right', fill='y')
        self.tree.configure(yscrollcommand=scroll.set)
        self.tree.bind('<<TreeviewSelect>>', self.show_details)
        self.tree.bind('<Double-1>', lambda _: self.open_selected('report'))
        self.detail = tk.StringVar(value='先添加文件，再点击开始处理。完成后双击一行即可查看结果。')
        detail_frame = ttk.Frame(workspace, style='Card.TFrame')
        detail_frame.pack(fill='x', pady=(10, 12))
        detail_view = tk.Text(detail_frame, height=3, wrap='word', font=('Microsoft YaHei UI', 9),
                              background='#f5f7fb', foreground='#53627a', relief='flat', padx=8, pady=5)
        detail_scroll = ttk.Scrollbar(detail_frame, orient='vertical', command=detail_view.yview)
        detail_scroll.pack(side='right', fill='y')
        detail_view.pack(side='left', fill='x', expand=True)
        def update_detail_scroll(first, last):
            detail_scroll.set(first, last)
            if float(first) <= 0 and float(last) >= 1:
                detail_scroll.pack_forget()
            elif not detail_scroll.winfo_manager():
                detail_scroll.pack(side='right', fill='y', before=detail_view)
        detail_view.configure(yscrollcommand=update_detail_scroll)
        def update_detail(*_args):
            detail_view.configure(state='normal')
            detail_view.delete('1.0', 'end')
            detail_view.insert('1.0', self.detail.get())
            detail_view.configure(state='disabled')
        self.detail.trace_add('write', update_detail)
        update_detail()
        ttk.Separator(workspace).pack(fill='x', pady=(0, 12))
        ttk.Label(workspace, text='查看与编辑', style='Section.TLabel').pack(anchor='w', pady=(0, 8))
        actions = ttk.Frame(workspace, style='Card.TFrame')
        actions.pack(fill='x')
        for label, action in [('打开 GP 草稿', 'draft'), ('查看分区 / 结果', 'report'), ('打开原文件', 'source')]:
            ttk.Button(actions, text=label, command=lambda a=action: self.open_selected(a)).pack(side='left', padx=(0, 8))
        actions_more = ttk.Frame(workspace, style='Card.TFrame')
        actions_more.pack(fill='x', pady=(8, 0))
        ttk.Button(actions_more, text='打开结果目录', command=lambda: self.open_selected('folder')).pack(side='left', padx=(0, 8))
        self.cleanup_button = ttk.Button(actions_more, text='清理中间文件', command=self.clean_selected)
        self.cleanup_button.pack(side='left')

        ttk.Label(sidebar, text='图片识别设置', style='Section.TLabel').pack(anchor='w', pady=(0, 8))
        settings = ttk.Frame(sidebar, style='Card.TFrame')
        settings.pack(fill='x')
        settings.columnconfigure((0, 1), weight=1)
        ttk.Label(settings, text='速度 BPM', style='Muted.TLabel').grid(row=0, column=0, sticky='w')
        ttk.Label(settings, text='拍号', style='Muted.TLabel').grid(row=0, column=1, sticky='w', padx=(8, 0))
        self.image_tempo = tk.StringVar(value='100')
        self.image_meter = tk.StringVar(value='4/4')
        self.tempo_input = ttk.Entry(settings, textvariable=self.image_tempo, width=8)
        self.tempo_input.grid(row=1, column=0, sticky='ew', pady=(4, 0))
        self.meter_input = ttk.Entry(settings, textvariable=self.image_meter, width=8)
        self.meter_input.grid(row=1, column=1, sticky='ew', padx=(8, 0), pady=(4, 0))
        ttk.Label(sidebar, text='定弦  ·  6 弦 → 1 弦', style='Muted.TLabel').pack(anchor='w', pady=(8, 4))
        self.image_tuning = tk.StringVar(value='E2 A2 D3 G3 B3 E4')
        self.tuning_input = ttk.Combobox(sidebar, textvariable=self.image_tuning,
            values=('E2 A2 D3 G3 B3 E4', 'D2 A2 D3 G3 B3 E4',
                    'Eb2 Ab2 Db3 Gb3 Bb3 Eb4', 'D2 G2 C3 F3 A3 D4'))
        self.tuning_input.pack(fill='x')
        ttk.Label(sidebar, text='音符、时值和技巧需在 GP 中核对；不确定时值会标 ?。',
                  style='Muted.TLabel', wraplength=260).pack(anchor='w', pady=(6, 0))
        ttk.Separator(sidebar).pack(fill='x', pady=8)
        ttk.Label(sidebar, text='教材 PDF', style='Section.TLabel').pack(anchor='w')
        ttk.Label(sidebar, text='先圈定谱面，再确认并拼接区域。', style='Muted.TLabel', wraplength=260).pack(anchor='w', pady=(4, 8))
        self.regions_button = ttk.Button(sidebar, text='划分乐谱区域', command=self.extract_selected, style='Compact.TButton')
        self.regions_button.pack(fill='x')
        self.region_plan_button = ttk.Button(sidebar, text='导入分区确认方案', command=self.import_region_plan, style='Compact.TButton')
        self.region_plan_button.pack(fill='x', pady=(6, 0))
        ttk.Separator(sidebar).pack(fill='x', pady=8)
        ttk.Label(sidebar, text='结果保存位置', style='Section.TLabel').pack(anchor='w')
        self.output = tk.StringVar(value=str(default_output()))
        ttk.Entry(sidebar, textvariable=self.output, state='readonly').pack(fill='x', pady=(8, 6))
        self.output_button = ttk.Button(sidebar, text='更改位置', command=self.choose_output, style='Compact.TButton')
        self.output_button.pack(fill='x')
        self.start_button = ttk.Button(sidebar, text='开始处理待处理文件', command=self.start, style='Primary.TButton')
        self.start_button.pack(fill='x', pady=(10, 0))
        self.stop_button = ttk.Button(sidebar, text='本文件完成后停止', command=self.request_stop, state='disabled', style='Compact.TButton')
        self.stop_button.pack(fill='x', pady=(6, 0))

        def scroll_settings(event):
            sidebar_canvas.yview_scroll(-int(event.delta / 120), 'units')
            return 'break'
        for widget in [sidebar, *sidebar.winfo_children(), *settings.winfo_children()]:
            if widget is not self.tuning_input:
                widget.bind('<MouseWheel>', scroll_settings, add='+')

        footer = ttk.Frame(outer)
        footer.pack(side='bottom', fill='x', pady=(10, 0), before=body)
        self.progress = ttk.Progressbar(footer, mode='indeterminate')
        self.progress.pack(fill='x', pady=(0, 5))
        self.status = tk.StringVar(value='就绪 · 文件不会上传')
        status_label = ttk.Label(footer, textvariable=self.status, background='#f2f5fa', foreground='#53627a',
                                 font=('Microsoft YaHei UI', 9), wraplength=1000)
        status_label.pack(anchor='w')
        footer.bind('<Configure>', lambda event: status_label.configure(wraplength=max(250, event.width)))
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

    def image_settings(self):
        from raster_tab import DEFAULT_SETTINGS, parse_tuning, validate_settings
        return validate_settings({**DEFAULT_SETTINGS, 'tempo': int(self.image_tempo.get()),
                                  'meter': [int(x) for x in self.image_meter.get().strip().split('/')],
                                  'tuning': parse_tuning(self.image_tuning.get())})

    def start(self):
        if self.running:
            return
        jobs = [(key, item['source']) for key, item in self.items.items() if item['pending']]
        if not jobs:
            messagebox.showinfo('没有待处理文件', '请先添加文件。重新试用同一文件时，可移除后再添加。')
            return
        output_root = Path(self.output.get())
        try:
            settings = self.image_settings()
            output_root.mkdir(parents=True, exist_ok=True)
        except (OSError, ValueError) as error:
            messagebox.showerror('请检查 BPM、拍号、定弦与输出位置', str(error))
            return
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.tuning_input, self.cleanup_button):
            button.configure(state='disabled')
        self.stop_button.configure(state='normal')
        self.progress.start(15)
        threading.Thread(target=self.work, args=(jobs, output_root, settings), daemon=True).start()

    def work(self, jobs, output_root, settings):
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
                        subprocess.run([sys.executable, str(ROOT / 'desktop_batch.py'), str(source), '--out', str(folder),
                                        '--image-settings', json.dumps(settings)],
                                       stdout=log, stderr=log, env=env, timeout=900, check=True,
                                       creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
                    result = json.loads((folder / 'result.json').read_text(encoding='utf-8'))
                    if not isinstance(result,dict) or not isinstance(result.get('status'),str) or not isinstance(result.get('message'),str):
                        raise ValueError('处理结果记录格式不完整')
                except Exception as error:
                    result = recover_draft_after_error(folder, error, source=source) or {
                        'status': '处理失败', 'message': f'{error}；可查看结果目录旁的 process.log',
                        'folder': str(folder) if folder else None, 'draft': None}
                self.events.put(('finished', key, result))
        finally:
            self.events.put(('done', '', ''))

    def request_stop(self):
        self.stop.set()
        self.stop_button.configure(state='disabled')
        self.status.set('将在当前文件处理完后停止；剩余文件保留为待处理。')

    def join_selected(self):
        if self.running:
            return
        selected = set(self.tree.selection())
        ordered = [self.items[key] for key in self.tree.get_children()
                   if key in selected and not self.items[key].get('is_join') and not self.items[key].get('is_regions')]
        sources = [item['source'] for item in ordered]
        if len(sources) < 2:
            messagebox.showinfo('选择多份原文件', '按住 Ctrl 或 Shift 选中至少两份 PDF / 截图，再设置拼接顺序和空白小节。')
            return
        from desktop_join_dialog import JoinDialog
        gap = 1 if any(self.items[key].get('from_textbook') for key in selected) else 0
        JoinDialog(self.root, [Path(s) for s in sources], self.start_join, default_gap=gap,
                   source_gaps=[item.get('gap_after',gap) for item in ordered])

    def extract_selected(self):
        if self.running:
            return
        selected = self.tree.selection()
        if len(selected) != 1 or Path(self.items[selected[0]]['source']).suffix.lower() != '.pdf':
            messagebox.showinfo('选择教材', '请选中一份 PDF；分区后可查看原页上的区域框，再拼接生成 GP。')
            return
        key = selected[0]
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button,
                       self.output_button, self.tempo_input, self.meter_input, self.tuning_input, self.cleanup_button):
            button.configure(state='disabled')
        self.stop_button.configure(state='normal')
        self.progress.start(15)
        threading.Thread(target=self.regions_work,
                         args=(key, Path(self.items[key]['source']), Path(self.output.get())), daemon=True).start()

    def regions_work(self, key, source, output_root):
        folder = None
        try:
            from textbook_regions import extract_regions
            folder = create_output(output_root, source.stem + '-分区.pdf')
            result = extract_regions(source, folder, stop=self.stop,
                                     progress=lambda text: self.events.put(('started', key, text)))
        except Exception as error:
            result = {'status': '分区失败', 'message': str(error), 'draft': None,
                      'folder': str(folder) if folder else None}
        self.events.put(('finished', key, result))
        self.events.put(('regions_ready', key, result.get('region_sources', [])))
        self.events.put(('done', '', result['status'] + ' · ' + result['message']))

    def import_region_plan(self):
        if self.running:
            return
        selected = self.tree.selection()
        item = self.items[selected[0]] if len(selected) == 1 else {}
        plan = filedialog.askopenfilename(title='选择浏览器保存的分区方案', filetypes=[('分区方案', '*.json')])
        if not plan:
            return
        try:
            saved = json.loads(Path(plan).read_text(encoding='utf-8'))
            if not isinstance(saved, dict):
                raise ValueError('请选择浏览器保存的 RiffLoop 分区方案')
            location = saved.get('review_folder') or (item.get('region_manifest_folder', item.get('folder')) if item.get('is_regions') else None)
            if not location or not (Path(location) / 'regions.json').is_file():
                location = filedialog.askdirectory(title='原分区目录已移动：选择包含 regions.json 的分区结果文件夹')
                if not location:
                    return
            source_folder = Path(location)
            manifest = json.loads((source_folder / 'regions.json').read_text(encoding='utf-8'))
            from region_review import validate_plan
            validate_plan(saved, manifest)
            source = Path(manifest['source'])
        except (OSError, ValueError, TypeError, KeyError) as error:
            messagebox.showerror('请检查分区方案', str(error))
            return
        key = self.tree.insert('', 'end', values=(source.stem + ' · 人工确认区域', '教材分区', '正在应用'))
        self.items[key] = {'source': source, 'pending': False, 'is_regions': True,
                           'region_manifest_folder': str(source_folder)}
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button,
                       self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.tuning_input, self.cleanup_button):
            button.configure(state='disabled')
        self.progress.start(15)
        threading.Thread(target=self.region_plan_work,
                         args=(key, Path(plan), source_folder, Path(self.output.get())), daemon=True).start()

    def region_plan_work(self, key, plan, source_folder, output_root):
        folder = None
        try:
            from region_review import apply_region_plan
            folder = create_output(output_root, '教材人工确认')
            result = apply_region_plan(plan, source_folder, folder)
        except Exception as error:
            result = {'status': '确认方案未应用', 'message': str(error), 'draft': None,
                      'folder': str(folder) if folder else None}
        self.events.put(('finished', key, result))
        self.events.put(('regions_ready', key, result.get('region_sources', [])))
        self.events.put(('done', '', result['status'] + ' · ' + result['message']))

    def start_join(self, sources, gaps, title):
        output_root = Path(self.output.get())
        try:
            settings = self.image_settings()
            output_root.mkdir(parents=True, exist_ok=True)
        except (OSError, ValueError) as error:
            messagebox.showerror('请检查 BPM、拍号、定弦与输出位置', str(error))
            return
        key = self.tree.insert('', 'end', values=(title, '拼接 GP', '待处理'))
        self.items[key] = {'source': Path(title + '.gp'), 'pending': False, 'is_join': True}
        self.tree.selection_set(key)
        self.tree.see(key)
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button,
                       self.tempo_input, self.meter_input, self.tuning_input, self.cleanup_button):
            button.configure(state='disabled')
        self.stop_button.configure(state='normal')
        self.progress.start(15)
        threading.Thread(target=self.join_work, args=(key, sources, gaps, title, output_root, settings), daemon=True).start()

    def join_work(self, key, sources, gaps, title, output_root, settings):
        folder = None
        try:
            from desktop_join import process_join
            folder = create_output(output_root, title + '.gp')
            result = process_join(sources, gaps, title, folder, settings, stop=self.stop,
                                  progress=lambda text: self.events.put(('started', key, text)))
        except Exception as error:
            result = recover_draft_after_error(folder, error, sources=sources) or {
                'status': '拼接失败', 'message': str(error), 'draft': None,
                'folder': str(folder) if folder else None}
        self.events.put(('finished', key, result))
        self.events.put(('done', '', ''))

    def clean_selected(self):
        if self.running:
            return
        jobs = [(key,self.items[key]['folder']) for key in self.tree.selection() if self.items[key].get('folder')]
        if not jobs:
            folder = filedialog.askdirectory(title='选择某次结果目录清理中间文件（GP 和原文件保留）', initialdir=self.output.get())
            if not folder:
                return
            jobs = [('',folder)]
        self.running = self.cleaning = True
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.tuning_input, self.cleanup_button):
            button.configure(state='disabled')
        self.progress.start(15)
        self.status.set('正在清理中间图片、识别缓存和日志；保留 GP、原文件及修改清单…')
        threading.Thread(target=self.clean_work, args=(jobs,), daemon=True).start()

    def clean_work(self, jobs):
        from desktop_cleanup import clean_intermediates
        freed, errors, skipped = 0, [], 0
        for key, folder in jobs:
            try:
                cleaned = clean_intermediates(folder)
                freed += cleaned['bytes_freed']
                skipped += len(cleaned['kept_modified_or_unowned'])
                errors.extend(cleaned['errors'])
                if key:
                    result = json.loads((Path(folder)/'result.json').read_text(encoding='utf-8'))
                    self.events.put(('finished',key,result))
            except Exception as error:
                errors.append(f'{Path(folder).name}：{error}')
        summary = f'清理完成 · 释放 {freed/1048576:.1f} MB · GP、原文件、修改清单保留'
        if skipped:
            summary += f' · {skipped} 个已修改/非缓存文件保留'
        if errors:
            summary += ' · 未清理项：' + '；'.join(errors)
        self.events.put(('cleanup_done','',summary))

    def poll(self):
        try:
            while True:
                event, key, payload = self.events.get_nowait()
                if event == 'started':
                    self.tree.set(key, 'status', '处理中…')
                    self.status.set(payload)
                elif event == 'finished':
                    if key not in self.items:
                        continue
                    if not isinstance(payload,dict) or not isinstance(payload.get('status'),str):
                        payload = {'status':'处理失败', 'message':'处理结果记录格式不完整，请查看结果目录或日志。', 'draft':None}
                    retry = (payload['status'] == '处理失败' and not self.items[key].get('is_join')
                             and not self.items[key].get('is_regions'))
                    self.items[key].update(payload, pending=retry)
                    self.tree.set(key, 'status', payload['status'])
                    self.show_details()
                elif event == 'regions_ready':
                    added = []
                    gaps = self.items[key].get('region_gaps',[1]*len(payload))
                    for index,path in enumerate(payload):
                        source = Path(path)
                        gap = gaps[index]
                        connection = f'后接空白 {gap} 小节' if gap else '后接连续写入'
                        row = self.tree.insert('', 'end', values=(source.name, '教材区域', '待处理 · '+connection))
                        self.items[row] = {'source': source, 'pending': True, 'from_textbook': True, 'gap_after':gap,
                            'region_report': str(Path(self.items[key]['folder']) / 'review.html'),
                            'message': '点击“查看分区 / 结果”看原页区域框；点击“拼接所选文件…”生成一份 GP。'
                                       +connection+'（若是最后一段则不追加空白）；只包含已确认页中采用的区域。'}
                        added.append(row)
                    if added:
                        self.tree.selection_set(added)
                        self.tree.see(added[0])
                        self.detail.set('已选中教材区域。点击“拼接所选文件…”生成一份 GP；按方案顺序及各段空白小节设置输出。'
                                        '选择原 PDF 行并查看结果，可浏览分区图和未采用候选。')
                elif event in ('done','cleanup_done'):
                    self.running = False
                    self.cleaning = False
                    self.progress.stop()
                    for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.tuning_input, self.cleanup_button):
                        button.configure(state='normal')
                    self.stop_button.configure(state='disabled')
                    count = sum(bool(v.get('draft')) for v in self.items.values())
                    failed = sum(v.get('status') == '处理失败' and v.get('pending') for v in self.items.values())
                    retry_hint = f' · {failed} 份处理失败，可重新点击开始处理' if failed else ''
                    self.status.set(payload or f'{"已停止" if self.stop.is_set() else "处理完成"} · 共 {count} 份 GP 草稿{retry_hint} · 双击文件行查看结果和待修改清单')
        except queue.Empty:
            pass
        finally:
            self.root.after(150, self.poll)

    def show_details(self, _event=None):
        selected = self.tree.selection()
        if selected:
            item = self.items[selected[0]]
            self.detail.set(str(item['source']) + '\n' + item.get('message', '待处理。默认 100 BPM、4/4；可修改设置。图片不确定时值将明确标记为占位。'))
        else:
            self.detail.set('选择文件行查看说明，双击打开结果。')

    def open_selected(self, action):
        selected = self.tree.selection()
        if not selected:
            messagebox.showinfo('选择文件', '请先选择列表中的一行。')
            return
        if len(selected) != 1:
            messagebox.showinfo('选择一份结果', '请只选择一行，再打开对应文件。')
            return
        item = self.items[selected[0]]
        if action == 'source' and item.get('is_join'):
            messagebox.showinfo('拼接原文件', '拼接结果包含多份原文件，请打开结果页面查看各片段。')
            return
        if action == 'draft' and not item.get('draft') and item.get('folder'):
            messagebox.showinfo('未生成 GP', item.get('message', '') + '\n请点击“查看分区 / 结果”。')
            return
        target = (Path(item['folder']) / 'review.html' if action == 'report' and item.get('folder')
                  else item.get('region_report') if action == 'report' else item.get(action))
        if not target or not Path(target).exists():
            messagebox.showinfo('尚无此结果', '此文件尚未生成对应结果。请查看处理状态或问题说明。')
            return
        try:
            os.startfile(str(target))
        except OSError as error:
            folder = item.get('folder')
            if folder:
                try:
                    with (Path(folder)/'open-error.log').open('a',encoding='utf-8') as log:
                        log.write(f'{datetime.now().astimezone().isoformat()} {action} {target}: {error!r}\n')
                except OSError:
                    pass
            messagebox.showinfo('无法打开', f'请使用支持此格式的软件打开，或打开结果目录。\n文件：{target}\n{error}')

    def close(self):
        if self.cleaning:
            messagebox.showinfo('正在清理', '清理完成后即可关闭，GP 和原文件会保留。')
        elif self.running:
            self.request_stop()
            messagebox.showinfo('正在处理文件', '已停止后续队列。当前文件完成后即可关闭窗口，结果会保留。')
        else:
            self.root.destroy()


if __name__ == '__main__':
    root = tk.Tk()
    app = TrialWindow(root)
    app.add_files(sys.argv[1:])
    root.mainloop()
