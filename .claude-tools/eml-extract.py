import email, sys, os, re, html
from email import policy
src, out = sys.argv[1], sys.argv[2]
msg = email.message_from_file(open(src, encoding='utf-8', errors='replace'), policy=policy.default)
n = 0
def walk(m, depth=0):
    global n
    for part in m.walk():
        ct = part.get_content_type()
        fn = part.get_filename()
        if ct == 'message/rfc822':
            continue
        if ct in ('text/plain', 'text/html') or (fn and fn.lower().endswith(('.txt', '.md', '.html', '.htm'))):
            try:
                txt = part.get_content()
            except Exception:
                txt = part.get_payload(decode=True).decode('utf-8', 'replace')
            if isinstance(txt, bytes):
                txt = txt.decode('utf-8', 'replace')
            if ct == 'text/html':
                txt = re.sub(r'(?is)<(script|style).*?</\1>', '', txt)
                txt = re.sub(r'(?i)<br\s*/?>|</p>|</div>|</li>|</h\d>|</tr>', '\n', txt)
                txt = html.unescape(re.sub(r'<[^>]+>', '', txt))
            n += 1
            name = f"{n:02d}_{ct.replace('/', '-')}_{(fn or 'body')}.txt"
            open(os.path.join(out, re.sub(r'[^\w.-]', '_', name)), 'w', encoding='utf-8').write(txt)
        elif fn:
            print('attachment', ct, fn)
walk(msg)
print('parts', n)
