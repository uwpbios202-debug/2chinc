import sys, email, re, html
from email import policy

for path in sys.argv[1:]:
    with open(path, 'rb') as f:
        msg = email.message_from_binary_file(f, policy=policy.default)
    print('=' * 100)
    print('FILE:', path.split('/')[-1])
    for h in ('Date', 'From', 'To', 'Subject'):
        print(f'{h}: {msg[h]}')
    body = None
    for part in msg.walk():
        ct = part.get_content_type()
        if part.get_filename():
            print('ATTACHMENT:', part.get_filename(), ct)
            continue
        if ct == 'text/plain' and body is None:
            body = part.get_content()
        elif ct == 'text/html' and body is None:
            h = part.get_content()
            h = re.sub(r'(?is)<(script|style).*?</\1>', '', h)
            h = re.sub(r'(?i)<br\s*/?>|</p>|</tr>|</div>|</li>|</h\d>', '\n', h)
            h = re.sub(r'(?i)</td>', ' | ', h)
            h = re.sub(r'<[^>]+>', '', h)
            body = html.unescape(h)
    if body:
        body = re.sub(r'[ \t\xa0]+', ' ', body)
        body = re.sub(r'\n\s*\n+', '\n', body)
        print(body.strip()[:6000])
