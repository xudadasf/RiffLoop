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
        self.cleaning = False
        root.title('RiffLoop · 图片 / PDF 草稿 · 支持拼接与空白分隔')
        root.geometry('1080x760')
        root.minsize(940, 760)
        style = ttk.Style(root)
        style.theme_use('clam')
        style.configure('.', font=('Microsoft YaHei UI', 10))
        style.configure('Treeview', rowheight=34)
        outer = ttk.Frame(root, padding=22)
        outer.pack(fill='both', expand=True)
        ttk.Label(outer, text='图片 / PDF → 可人工修改的 GP 草稿', font=('Microsoft YaHei UI', 19, 'bold')).pack(anchor='w')
        ttk.Label(outer, text='批量选择 PDF、截图或照片；可单独处理，也可选中多份拼接为一份 GP。', foreground='#46576b').pack(anchor='w', pady=(8, 4))
        ttk.Label(outer, text='图片识别数字与横梁；不确定时值按默认值占位并标 ?。完成后可打开 GP 和待修改清单。', foreground='#92520a').pack(anchor='w', pady=(0, 12))
        controls = ttk.Frame(outer)
        controls.pack(fill='x')
        self.add_button = ttk.Button(controls, text='添加 PDF / 截图', command=self.choose_files)
        self.add_button.pack(side='left')
        self.remove_button = ttk.Button(controls, text='移除所选', command=self.remove)
        self.remove_button.pack(side='left', padx=8)
        self.start_button = ttk.Button(controls, text='开始处理待处理文件', command=self.start)
        self.start_button.pack(side='left', padx=8)
        self.join_button = ttk.Button(controls, text='拼接所选文件…', command=self.join_selected)
        self.join_button.pack(side='left', padx=(0, 8))
        self.stop_button = ttk.Button(controls, text='本文件完成后停止', command=self.request_stop, state='disabled')
        self.stop_button.pack(side='left')
        textbook_row = ttk.Frame(outer)
        textbook_row.pack(fill='x', pady=(8, 0))
        self.regions_button = ttk.Button(textbook_row, text='教材 PDF：先划分乐谱区域', command=self.extract_selected)
        self.regions_button.pack(side='left')
        self.region_plan_button = ttk.Button(textbook_row, text='导入分区确认方案', command=self.import_region_plan)
        self.region_plan_button.pack(side='left', padx=8)
        ttk.Label(textbook_row, text='先确定完整区域，再识别；默认空 1 小节。',
                  foreground='#46576b').pack(side='left', padx=8)
        output_row = ttk.Frame(outer)
        output_row.pack(fill='x', pady=12)
        self.output = tk.StringVar(value=str(default_output()))
        ttk.Label(output_row, text='结果保存到：').pack(side='left')
        ttk.Entry(output_row, textvariable=self.output, state='readonly').pack(side='left', fill='x', expand=True)
        self.output_button = ttk.Button(output_row, text='更改位置', command=self.choose_output)
        self.output_button.pack(side='left', padx=(8, 0))
        settings_row = ttk.Frame(outer)
        settings_row.pack(fill='x', pady=(0, 12))
        ttk.Label(settings_row, text='图片默认设置：BPM').pack(side='left')
        self.image_tempo = tk.StringVar(value='100')
        self.image_meter = tk.StringVar(value='4/4')
        self.tempo_input = ttk.Entry(settings_row, textvariable=self.image_tempo, width=6)
        self.tempo_input.pack(side='left', padx=8)
        ttk.Label(settings_row, text='拍号').pack(side='left')
        self.meter_input = ttk.Entry(settings_row, textvariable=self.image_meter, width=6)
        self.meter_input.pack(side='left', padx=8)
        ttk.Label(settings_row, text='可修改；人工设置，不代表已识别每个音符的时值。', foreground='#92520a').pack(side='left')
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
        for label, action in [('查看分区 / 结果', 'report'), ('打开 GP 草稿', 'draft'), ('打开原文件', 'source'), ('打开该文件结果目录', 'folder')]:
            ttk.Button(actions, text=label, command=lambda a=action: self.open_selected(a)).pack(side='left', padx=(0, 8))
        self.cleanup_button = ttk.Button(actions, text='清理中间文件', command=self.clean_selected)
        self.cleanup_button.pack(side='left')
        ttk.Label(outer, text='保存修正后的 GP 后，可选中结果清理中间文件；未选中时可选择以前的结果目录。原文件和所有 GP 均保留。',
                  foreground='#46576b', wraplength=880).pack(anchor='w', pady=(8, 0))
        self.progress = ttk.Progressbar(outer, mode='indeterminate')
        self.progress.pack(fill='x', pady=(16, 8))
        self.status = tk.StringVar(value='就绪 · 文件不会上传')
        status_label = ttk.Label(outer, textvariable=self.status, wraplength=990)
        status_label.pack(anchor='w')
        notice_label = ttk.Label(outer, text=NOTICE, wraplength=990, foreground='#92520a')
        notice_label.pack(anchor='w', pady=(12, 0))
        outer.bind('<Configure>', lambda event: [label.configure(wraplength=max(400, event.width - 44))
                                                for label in (detail_label, status_label, notice_label)])
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
            from raster_tab import DEFAULT_SETTINGS, validate_settings
            settings = validate_settings({**DEFAULT_SETTINGS, 'tempo': int(self.image_tempo.get()),
                                          'meter': [int(x) for x in self.image_meter.get().strip().split('/')]})
            output_root.mkdir(parents=True, exist_ok=True)
        except (OSError, ValueError) as error:
            messagebox.showerror('请检查 BPM、拍号与输出位置', str(error))
            return
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.cleanup_button):
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

    def join_selected(self):
        if self.running:
            return
        selected = set(self.tree.selection())
        sources = [self.items[key]['source'] for key in self.tree.get_children()
                   if key in selected and not self.items[key].get('is_join') and not self.items[key].get('is_regions')]
        if len(sources) < 2:
            messagebox.showinfo('选择多份原文件', '按住 Ctrl 或 Shift 选中至少两份 PDF / 截图，再设置拼接顺序和空白小节。')
            return
        from desktop_join_dialog import JoinDialog
        gap = 1 if any(self.items[key].get('from_textbook') for key in selected) else 0
        JoinDialog(self.root, [Path(s) for s in sources], self.start_join, default_gap=gap)

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
                       self.output_button, self.tempo_input, self.meter_input, self.cleanup_button):
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
                       self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.cleanup_button):
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
            from raster_tab import DEFAULT_SETTINGS, validate_settings
            settings = validate_settings({**DEFAULT_SETTINGS, 'tempo': int(self.image_tempo.get()),
                                          'meter': [int(x) for x in self.image_meter.get().strip().split('/')]})
            output_root.mkdir(parents=True, exist_ok=True)
        except (OSError, ValueError) as error:
            messagebox.showerror('请检查 BPM、拍号与输出位置', str(error))
            return
        key = self.tree.insert('', 'end', values=(title, '拼接 GP', '待处理'))
        self.items[key] = {'source': Path(title + '.gp'), 'pending': False, 'is_join': True}
        self.tree.selection_set(key)
        self.tree.see(key)
        self.running = True
        self.stop.clear()
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button,
                       self.tempo_input, self.meter_input, self.cleanup_button):
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
            result = {'status': '拼接失败', 'message': str(error), 'draft': None,
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
        for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.cleanup_button):
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
                    self.items[key].update(payload, pending=False)
                    self.tree.set(key, 'status', payload['status'])
                    self.show_details()
                elif event == 'regions_ready':
                    added = []
                    for path in payload:
                        source = Path(path)
                        row = self.tree.insert('', 'end', values=(source.name, '教材区域', '待处理 · 区域间默认空 1 小节'))
                        self.items[row] = {'source': source, 'pending': True, 'from_textbook': True,
                            'region_report': str(Path(self.items[key]['folder']) / 'review.html'),
                            'message': '点击“查看分区 / 结果”看原页区域框；点击“拼接所选文件…”生成一份 GP。'
                                       '区域间默认空 1 小节，连续谱可改为 0；只包含已确认页中采用的区域。'}
                        added.append(row)
                    if added:
                        self.tree.selection_set(added)
                        self.tree.see(added[0])
                        self.detail.set('已选中教材区域。点击“拼接所选文件…”生成一份 GP；默认每个区域间空 1 小节。'
                                        '选择原 PDF 行并查看结果，可浏览分区图和未采用候选。')
                elif event in ('done','cleanup_done'):
                    self.running = False
                    self.cleaning = False
                    self.progress.stop()
                    for button in (self.add_button, self.remove_button, self.start_button, self.join_button, self.regions_button, self.region_plan_button, self.output_button, self.tempo_input, self.meter_input, self.cleanup_button):
                        button.configure(state='normal')
                    self.stop_button.configure(state='disabled')
                    count = sum(bool(v.get('draft')) for v in self.items.values())
                    self.status.set(payload or f'{"已停止" if self.stop.is_set() else "处理完成"} · 共 {count} 份 GP 草稿 · 双击文件行查看结果和待修改清单')
        except queue.Empty:
            pass
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
        item = self.items[selected[0]]
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
            messagebox.showinfo('无法打开', f'请使用支持此格式的软件打开，或打开结果目录。\n{error}')

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
