"""Choose source order and independent gaps before joining a draft."""
import tkinter as tk
from tkinter import messagebox, ttk

from desktop_join import validate_join


class JoinDialog(tk.Toplevel):
    def __init__(self, parent, sources, submit, default_gap=0):
        super().__init__(parent)
        self.title('拼接生成一份 GP')
        self.geometry('780x520')
        self.minsize(680, 520)
        self.transient(parent)
        self.submit = submit
        self.sources = {str(i): source for i, source in enumerate(sources)}
        self.gaps = {key: tk.StringVar(value=str(default_gap)) for key in self.sources}
        self.last_gap = tk.StringVar(value='0')
        outer = ttk.Frame(self, padding=18)
        outer.pack(fill='both', expand=True)
        ttk.Label(outer, text='按列表从上到下拼接，每个连接处可单独留白。').pack(anchor='w')
        ttk.Label(outer, text='0 = 直接连接；空白小节也会参与播放，拍号沿用前一片段。', foreground='#92520a').pack(anchor='w', pady=(4, 10))
        title_row = ttk.Frame(outer)
        title_row.pack(fill='x', pady=(0, 10))
        ttk.Label(title_row, text='谱名：').pack(side='left')
        self.score_title = tk.StringVar(value='拼接练习谱')
        ttk.Entry(title_row, textvariable=self.score_title).pack(side='left', fill='x', expand=True)
        table = ttk.Frame(outer)
        table.pack(fill='both', expand=True)
        self.tree = ttk.Treeview(table, columns=('order', 'file', 'gap'), show='headings', selectmode='browse', height=4)
        for key, label, width in [('order', '顺序', 55), ('file', '文件', 430), ('gap', '之后空白小节', 120)]:
            self.tree.heading(key, text=label)
            self.tree.column(key, width=width, minwidth=45)
        self.tree.pack(side='left', fill='both', expand=True)
        scroll = ttk.Scrollbar(table, orient='vertical', command=self.tree.yview)
        scroll.pack(side='right', fill='y')
        self.tree.configure(yscrollcommand=scroll.set)
        for key in self.sources:
            self.tree.insert('', 'end', iid=key)
            self.gaps[key].trace_add('write', lambda *_: self.refresh())
        row = ttk.Frame(outer)
        row.pack(fill='x', pady=12)
        ttk.Button(row, text='上移', command=lambda: self.move(-1)).pack(side='left')
        ttk.Button(row, text='下移', command=lambda: self.move(1)).pack(side='left', padx=8)
        ttk.Label(row, text='所选片段之后空白：').pack(side='left')
        self.gap_input = ttk.Spinbox(row, from_=0, to=99, width=5)
        self.gap_input.pack(side='left')
        ttk.Label(row, text=' 小节（最后一份不追加）').pack(side='left')
        region_note = '教材仅拼接已确认页中采用的区域；未确认页不包含。\n' if default_gap else ''
        ttk.Label(outer, text=region_note + '截图应按完整小节切分；重叠内容不会自动去重。\n将从原文件生成新草稿，不带入已在 Guitar Pro 中手工修改的内容。',
                  foreground='#46576b', wraplength=700).pack(anchor='w')
        actions = ttk.Frame(outer)
        actions.pack(fill='x', pady=(12, 0))
        ttk.Button(actions, text='开始拼接', command=self.confirm).pack(side='right')
        ttk.Button(actions, text='取消', command=self.destroy).pack(side='right', padx=8)
        self.tree.bind('<<TreeviewSelect>>', self.select)
        self.refresh()
        self.tree.selection_set('0')
        self.select()
        self.grab_set()

    def refresh(self):
        keys = self.tree.get_children()
        for index, key in enumerate(keys):
            self.tree.item(key, values=(index + 1, self.sources[key].name,
                                      self.gaps[key].get() if index < len(keys)-1 else '—'))

    def select(self, _event=None):
        selected = self.tree.selection()
        if selected:
            key = selected[0]
            last = key == self.tree.get_children()[-1]
            self.gap_input.configure(textvariable=self.last_gap if last else self.gaps[key],
                                     state='disabled' if last else 'normal')

    def move(self, direction):
        if not self.tree.selection():
            return
        key = self.tree.selection()[0]
        index = self.tree.index(key)
        target = index + direction
        if 0 <= target < len(self.sources):
            self.tree.move(key, '', target)
            self.tree.see(key)
            self.refresh()
            self.select()

    def confirm(self):
        keys = self.tree.get_children()
        sources = [self.sources[key] for key in keys]
        try:
            gaps = [int(self.gaps[key].get()) for key in keys[:-1]]
            title = self.score_title.get().strip()
            validate_join(sources, gaps, title)
        except ValueError as error:
            messagebox.showerror('请检查拼接设置', str(error), parent=self)
            return
        self.destroy()
        self.submit(sources, gaps, title)
