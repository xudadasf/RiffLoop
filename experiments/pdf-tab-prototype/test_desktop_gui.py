import json
from pathlib import Path
import queue
import subprocess
import tempfile
import threading
import tkinter as tk
from tkinter import ttk
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

from desktop_gui import TrialWindow


class DesktopGuiStateTests(unittest.TestCase):
    def test_long_detail_keeps_result_buttons_visible(self):
        try:
            root = tk.Tk()
        except tk.TclError:
            self.skipTest('GUI display unavailable')
        try:
            root.attributes('-alpha', 0.0)
            window = TrialWindow(root)
            root.geometry('940x760')
            window.detail.set('很长的文件路径和处理说明。' * 100)
            root.update()
            buttons = {}
            def collect(parent):
                for child in parent.winfo_children():
                    if isinstance(child, ttk.Button):
                        buttons[child.cget('text')] = child
                    collect(child)
            collect(root)
            for label in ('打开 GP 草稿', '查看分区 / 结果', '打开结果目录', '清理中间文件'):
                button = buttons[label]
                self.assertGreaterEqual(button.winfo_width(), button.winfo_reqwidth(), label)
                self.assertGreaterEqual(button.winfo_height(), button.winfo_reqheight(), label)
        finally:
            root.destroy()

    def test_completed_gp_is_available_if_worker_fails_after_export(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root/'source.png'; source.write_bytes(b'source')
            folder = root/'result'; folder.mkdir()
            draft = folder/'score.draft.gp'
            def worker(*args, **kwargs):
                draft.write_bytes(b'generated draft')
                (folder/'score.draft.gp.review.json').write_text(json.dumps({'roundtrip':'passed; serialized content only'}), encoding='utf-8')
                (folder/'result.json').write_text(json.dumps({'source':str(source), 'folder':str(folder),
                    'draft':str(draft), 'status':'图片草稿已生成 · 含占位', 'message':'需核对'}), encoding='utf-8')
                raise subprocess.CalledProcessError(1, 'worker')
            window = SimpleNamespace(stop=threading.Event(), events=queue.Queue())
            with patch('desktop_gui.create_output', return_value=folder), patch('desktop_gui.subprocess.run', side_effect=worker):
                TrialWindow.work(window, [('row',source)], root, {})
            event, key, result = window.events.get_nowait()
            self.assertEqual(event, 'started')
            event, key, result = window.events.get_nowait()
            self.assertEqual((event,key), ('finished','row'))
            self.assertEqual(result['draft'], str(draft))
            self.assertIn('后处理', result['message'])
            self.assertTrue(draft.is_file())

    def test_worker_error_does_not_trust_unverified_or_external_draft(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root/'source.png'; source.write_bytes(b'source')
            folder = root/'result'; folder.mkdir()
            external = root/'unrelated.draft.gp'; external.write_bytes(b'user file')
            def worker(*args, **kwargs):
                (folder/'result.json').write_text(json.dumps({'source':str(source), 'folder':str(folder),
                    'draft':str(external), 'status':'完成', 'message':'test'}), encoding='utf-8')
                raise subprocess.CalledProcessError(1, 'worker')
            window = SimpleNamespace(stop=threading.Event(), events=queue.Queue())
            with patch('desktop_gui.create_output', return_value=folder), patch('desktop_gui.subprocess.run', side_effect=worker):
                TrialWindow.work(window, [('row',source)], root, {})
            window.events.get_nowait()
            _, _, result = window.events.get_nowait()
            self.assertEqual(result['status'], '处理失败')
            self.assertIsNone(result['draft'])

    def test_join_draft_survives_report_failure_only_with_matching_readback(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);folder=root/'joined';folder.mkdir()
            sources=[root/'a.png',root/'b.png']
            draft=folder/'score.draft.gp'
            def worker(*args, **kwargs):
                draft.write_bytes(b'joined draft')
                review={'roundtrip':'passed; serialized content only',
                        'join_parts':[{'source':str(s)} for s in sources]}
                (folder/'score.draft.gp.review.json').write_text(json.dumps(review),encoding='utf-8')
                raise OSError('report cannot be saved')
            window=SimpleNamespace(stop=threading.Event(), events=queue.Queue())
            with patch('desktop_gui.create_output',return_value=folder), patch('desktop_join.process_join',side_effect=worker):
                TrialWindow.join_work(window,'row',sources,[1],'练习',root,{})
            _,_,result=window.events.get_nowait()
            self.assertEqual(result['draft'],str(draft))
            self.assertIn('后处理',result['message'])

    def test_join_draft_is_not_recovered_from_mismatched_review(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);folder=root/'joined';folder.mkdir()
            sources=[root/'a.png',root/'b.png']
            def worker(*args, **kwargs):
                (folder/'score.draft.gp').write_bytes(b'draft')
                (folder/'score.draft.gp.review.json').write_text(json.dumps({'roundtrip':'passed',
                    'join_parts':[{'source':str(root/'other.png')}]}),encoding='utf-8')
                raise OSError('report cannot be saved')
            window=SimpleNamespace(stop=threading.Event(), events=queue.Queue())
            with patch('desktop_gui.create_output',return_value=folder), patch('desktop_join.process_join',side_effect=worker):
                TrialWindow.join_work(window,'row',sources,[1],'练习',root,{})
            _,_,result=window.events.get_nowait()
            self.assertIsNone(result['draft'])

    def test_join_recovery_uses_actual_gp_export_and_readback(self):
        from test_desktop_join import part
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);folder=root/'joined';folder.mkdir()
            sources=[root/'a.png',root/'b.png']
            def make_part(source, target, settings):
                target.mkdir()
                (target/'recognized.json').write_text(json.dumps(part(source.name,3,image=False)['score']),encoding='utf-8')
                return {'draft':str(target/'score.draft.gp')}
            window=SimpleNamespace(stop=threading.Event(), events=queue.Queue())
            with patch('desktop_gui.create_output',return_value=folder), \
                 patch('desktop_join.process_file',side_effect=make_part), \
                 patch('desktop_join.write_report',side_effect=OSError('report failure')):
                TrialWindow.join_work(window,'row',sources,[1],'练习',root,{})
            events=[]
            while not window.events.empty():events.append(window.events.get_nowait())
            result=next(payload for event,_,payload in events if event=='finished')
            self.assertEqual(result['draft'],str(folder/'score.draft.gp'))
            review=json.loads((folder/'score.draft.gp.review.json').read_text(encoding='utf-8'))
            self.assertTrue(review['roundtrip'].startswith('passed'))

    def test_multiple_selection_does_not_open_the_wrong_file(self):
        with tempfile.TemporaryDirectory() as temp:
            draft = Path(temp)/'score.draft.gp'; draft.write_bytes(b'draft')
            tree = Mock(); tree.selection.return_value = ('a','b')
            window = SimpleNamespace(tree=tree, items={'a':{'draft':str(draft)},'b':{'draft':str(draft)}})
            with patch('desktop_gui.messagebox.showinfo') as alert, patch('desktop_gui.os.startfile') as open_file:
                TrialWindow.open_selected(window, 'draft')
            alert.assert_called_once()
            open_file.assert_not_called()

    def test_single_selected_draft_opens(self):
        with tempfile.TemporaryDirectory() as temp:
            draft = Path(temp)/'score.draft.gp'; draft.write_bytes(b'draft')
            tree = Mock(); tree.selection.return_value = ('a',)
            window = SimpleNamespace(tree=tree, items={'a':{'draft':str(draft)}})
            with patch('desktop_gui.os.startfile') as open_file:
                TrialWindow.open_selected(window, 'draft')
            open_file.assert_called_once_with(str(draft))

    def test_open_failure_reports_path_and_keeps_a_local_error_record(self):
        with tempfile.TemporaryDirectory() as temp:
            folder=Path(temp); draft=folder/'score.draft.gp';draft.write_bytes(b'draft')
            tree=Mock();tree.selection.return_value=('a',)
            window=SimpleNamespace(tree=tree,items={'a':{'draft':str(draft),'folder':str(folder)}})
            with patch('desktop_gui.os.startfile',side_effect=OSError('association failed')), \
                 patch('desktop_gui.messagebox.showinfo') as alert:
                TrialWindow.open_selected(window,'draft')
            self.assertIn(str(draft),alert.call_args.args[1])
            self.assertIn('association failed',(folder/'open-error.log').read_text(encoding='utf-8'))

    def test_invalid_worker_result_is_a_failure_not_a_broken_gui_event(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp); source = root/'source.png'; source.write_bytes(b'source')
            folder = root/'result'; folder.mkdir()
            def worker(*args, **kwargs):
                (folder/'result.json').write_text('{}', encoding='utf-8')
            window = SimpleNamespace(stop=threading.Event(), events=queue.Queue())
            with patch('desktop_gui.create_output', return_value=folder), patch('desktop_gui.subprocess.run', side_effect=worker):
                TrialWindow.work(window, [('row',source)], root, {})
            window.events.get_nowait()
            _, _, result = window.events.get_nowait()
            self.assertEqual(result['status'], '处理失败')
            self.assertIsNone(result['draft'])

    def test_bad_finished_event_does_not_stop_completion_polling(self):
        window = SimpleNamespace(events=queue.Queue(), items={'row':{'source':'a.png'}}, tree=Mock(),
                                 root=Mock(), show_details=Mock(), status=Mock(), progress=Mock(),
                                 stop=threading.Event(), running=True, cleaning=False)
        for name in ('add_button','remove_button','start_button','join_button','regions_button','region_plan_button',
                     'output_button','tempo_input','meter_input','tuning_input','cleanup_button','stop_button'):
            setattr(window,name,Mock())
        window.poll = Mock()
        window.events.put(('finished','row',{}));window.events.put(('done','',''))
        TrialWindow.poll(window)
        self.assertFalse(window.running)
        self.assertEqual(window.items['row']['status'],'处理失败')
        self.assertTrue(window.items['row']['pending'])
        window.root.after.assert_called_once()

    def test_joined_result_explains_there_are_multiple_originals(self):
        tree=Mock();tree.selection.return_value=('a',)
        window=SimpleNamespace(tree=tree,items={'a':{'is_join':True,'source':'nonexistent.gp'}})
        with patch('desktop_gui.messagebox.showinfo') as alert, patch('desktop_gui.os.startfile') as launch:
            TrialWindow.open_selected(window,'source')
        self.assertIn('原文件',alert.call_args.args[1])
        self.assertIn('结果',alert.call_args.args[1])
        launch.assert_not_called()


if __name__ == '__main__':
    unittest.main()
