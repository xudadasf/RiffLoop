'use strict';

class GuitarSourceReference {
  constructor(request, display) {
    this.request = request;
    this.display = display;
    this.open = false;
    this.token = 0;
    this.key = undefined;
  }

  setOpen(open, source) {
    this.open = open;
    this.key = undefined;
    if (open) this.follow(source);
    else {
      this.request('cancelSource', {token: ++this.token});
      this.display({open: false});
    }
  }

  follow(source) {
    if (!this.open) return;
    const r = source?.region;
    // The page and coordinates also distinguish regions in older documents.
    const key = r ? JSON.stringify([source.name, source.digest, source.page, r.id, r.x, r.y, r.width, r.height, source.referenceTop]) : null;
    if (key === this.key) return;
    this.key = key;
    const token = ++this.token;
    if (!r) {
      this.request('cancelSource', {token});
      this.display({open: true, label: '此小节没有对应原图'});
      return;
    }
    this.display({open: true, label: '正在读取第 ' + (source.page + 1) + ' 页原图…'});
    this.request('source', {token, source});
  }

  receive(result) {
    if (!this.open || result.token !== this.token) return;
    this.display({open: true, label: result.label, image: result.image});
    if (!result.image) this.key = undefined; // Allow another attempt on the next edit.
  }
}
if (typeof module !== 'undefined' && module.exports) module.exports = GuitarSourceReference;
