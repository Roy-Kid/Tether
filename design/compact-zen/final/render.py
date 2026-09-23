from pathlib import Path
from html import escape
import json
BG='#15181D'; PANEL='#1C2026'; BAR='#20252C'; LINE='#303640'; TXT='#D9DFE8'; MUTED='#8993A3'; ACC='#8FAEF0'; GREEN='#8EC9AD'

def rect(x,y,w,h,c,r=0): return f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{c}"/>'
def text(x,y,t,size=12,c=TXT,mono=False,weight=400): return f'<text x="{x}" y="{y}" fill="{c}" font-family="{("JetBrains Mono" if mono else "Inter")}" font-size="{size}" font-weight="{weight}">{escape(t)}</text>'
def line(x,y,x2,y2): return f'<path d="M{x} {y}H{x2}" stroke="{LINE}"/>' if y==y2 else f'<path d="M{x} {y}L{x2} {y2}" stroke="{LINE}"/>'
def term(x,y,variant='main'):
    rows={
    'main':[('roy@localhost  ~/work/tether',ACC),('❯ git status --short',TXT),(' M app/Sources/TetherApp/WorkspaceView.swift',MUTED),(' M app/Sources/TetherApp/Design.swift',MUTED),('',TXT),('❯ swift test --package-path app',TXT),('Building for debugging…',MUTED),('Build complete! (2.31s)',MUTED),('',TXT),('◇ Test run started.',TXT),('✔ Workspace layout restores after Zen Mode',GREEN),('✔ Terminal focus survives layout changes',GREEN),('✔ Closing the last workspace exits Zen Mode',GREEN),('✔ Test run with 3 tests passed.',GREEN),('',TXT),('roy@localhost  ~/work/tether',ACC),('❯',TXT)],
    'editor':[('~/work/tether   main',ACC),('',TXT),('  1  struct WorkspaceView: View {',TXT),('  2    @Environment(\\.isZenMode)',MUTED),('  3    private var isZenMode',TXT),('  4',MUTED),('  5    var body: some View {',TXT),('  6      VStack(spacing: 0) {',TXT),('  7        if !isZenMode {',ACC),('  8          workspaceTabs',TXT),('  9        }',TXT),(' 10        terminal',TXT),(' 11      }',TXT),(' 12    }',TXT),(' 13  }',TXT)],
    'logs':[('❯ swift build --package-path app',TXT),('Building for debugging…',MUTED),('[4/4] Linking TetherApp',MUTED),('Build complete! (1.82s)',GREEN),('',TXT),('❯',TXT)],
    'git':[('❯ git diff --stat',TXT),(' Design.swift         | 24 +++++',MUTED),(' WorkspaceView.swift  | 48 +++++',MUTED),(' 2 files changed',GREEN),('',TXT),('❯',TXT)]}[variant]
    return ''.join(text(x,y+i*21,s,13,c,True) for i,(s,c) in enumerate(rows))

def svg(content,w,h): return f'<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 {w} {h}">{content}</svg>'
def screen(expand=False):
 s=rect(0,0,1100,700,BG,10)+rect(0,0,1100,36,PANEL,10)+rect(0,26,1100,10,PANEL)
 for x,c in [(19,'#F27770'),(39,'#E5BC63'),(59,'#83BB85')]:s+=f'<circle cx="{x}" cy="18" r="5" fill="{c}"/>'
 s+=rect(87,0,233,36,'#2B3441')+rect(97,34,213,2,ACC)+text(102,23,'Terminal 1',12,TXT)+text(181,23,'dev / editor',10,MUTED)+text(297,23,'▾',12,TXT)+text(337,23,'Terminal 2  ▾',12,MUTED)
 s+=line(0,36,1100,36)+term(20,70,'editor')+line(672,36,672,676)+term(692,70,'logs')+line(672,350,1100,350)+term(692,380,'git')+rect(0,36,2,640,ACC)+rect(0,676,1100,24,PANEL)+text(12,692,'● localhost ▾',11,TXT)+text(179,692,'Connected · tmux',10,MUTED)
 if expand:
  s+=rect(87,42,300,281,'#252B33',6)+text(103,66,'LOCALHOST',10,MUTED,weight=600)+text(105,97,'›_  Original shell',12,TXT)+line(100,112,374,112)+text(103,135,'TMUX SESSIONS',10,MUTED,weight=600)
  s+=rect(94,146,286,41,'#344052',4)+text(106,163,'✓ dev',13,TXT)+text(127,178,'3 windows · editor active',10,MUTED)+text(366,170,'›',16,TXT)+text(106,207,'ops',13,TXT)+text(127,223,'2 windows',10,MUTED)+text(366,213,'›',16,MUTED)+line(100,238,374,238)+text(106,259,'Create tmux session…',12,TXT)+text(106,289,'Refresh sessions',12,MUTED)+text(106,309,'Session actions available by right-click',10,MUTED)
  s+=rect(391,146,304,176,'#252B33',6)+text(407,170,'DEV · WINDOWS',10,MUTED,weight=600)
  for i,(a,b) in enumerate([('✓ 1  editor','3 panes'),('   2  server','1 pane'),('   3  logs','2 panes')]):
   y=197+i*35
   if i==0:s+=rect(397,y-18,292,30,'#344052',4)
   s+=text(408,y,a,12,TXT)+text(622,y,b,10,MUTED)
  s+=line(404,282,682,282)+text(410,307,'New window',12,TXT)
 return s
p=Path(__file__).parent

def plain():
 s=screen().replace('dev / editor','Original shell').replace('Connected · tmux','Connected · Shell')
 s+=rect(0,36,1100,640,BG)+term(20,70,'git')
 return s

def popup(x,y,w,h):return rect(x+2,y+4,w,h,'#0C0F13',7)+rect(x,y,w,h,'#252B33',7)
def button(x,y,w,label):return rect(x,y,w,30,'#35465F',5)+text(x+12,y+20,label,12,TXT)
def sheet(title,subtitle,rows,action):
 s=plain()+rect(278,139,544,420,'#252B33',10)+text(302,178,title,21,TXT,weight=600)+text(302,208,subtitle,12,MUTED)
 for i,(label,value) in enumerate(rows):
  y=243+i*59;s+=text(302,y,label,11,MUTED)+rect(302,y+9,496,29,'#191E25',4)+text(313,y+29,value,12,TXT)
 s+=button(572,508,98,'Cancel')+button(682,508,116,action)
 return s

def host():
 s=screen()+popup(12,320,355,344)+rect(24,332,331,30,'#191E25',4)+text(35,353,'Find a host…',12,MUTED)+text(27,387,'CONNECTED',10,MUTED,weight=600)
 for i,(a,b) in enumerate([('✓ localhost','Local machine · Terminal 1 / dev'),('production','deploy@prod.example.com · ops / logs'),('lab','roy@lab.example.com · Terminal 2')]):
  y=410+i*55
  if i==0:s+=rect(20,y-15,339,47,'#344052',4)
  s+=text(32,y,a,13,TXT)+text(32,y+18,b,10,MUTED)
 s+=line(25,560,353,560)+text(32,584,'staging · Not connected',12,MUTED)+line(25,605,353,605)+text(32,635,'Add host…',12,TXT)+text(220,635,'Manage hosts…',12,TXT)
 return s

def command(quick=False):
 s=screen()+popup(264,94,572,346)+rect(276,106,548,34,'#191E25',4)+text(289,128,'logs' if quick else 'Type a command…',13,TXT)
 if quick:
  rows=[('production / ops / logs','tmux window · 2 panes'),('localhost / dev / logs','tmux window · 2 panes'),('lab / Terminal 2','Shell · Disconnected')]
  for i,(a,b) in enumerate(rows):
   y=176+i*66
   if i==0:s+=rect(272,y-21,556,58,'#344052',4)
   s+=text(290,y,a,14,TXT)+text(290,y+21,b,11,MUTED)
 else:
  for i,(a,b) in enumerate([('New terminal','⌘N'),('New tmux window','⌘⇧N'),('Split left and right','⌘\\'),('Split top and bottom','⌘⇧\\'),('Zoom pane','⌘⇧↵'),('Enter Zen Mode','⌘⇧Z')]):
   y=172+i*34
   if i==2:s+=rect(272,y-21,556,31,'#344052',4)
   s+=text(290,y,a,13,TXT)+text(751,y,b,11,MUTED)
 s+=line(278,398,820,398)+text(291,423,'↑↓ / Ctrl-N P  Navigate     ↵ Confirm     esc Cancel',11,MUTED)
 return s

def menus():
 s=screen()+popup(313,0,331,552)
 rows=[('Attach session…',''),('Create session…',''),('Detach current session',''),('New window','⌘⇧N'),('Split left and right','⌘\\'),('Split top and bottom','⌘⇧\\'),('Zoom pane','⌘⇧↵'),('Focus pane','›'),('Previous / next window','›'),('Rename','›'),('End pane…',''),('End window…',''),('End session…','')]
 for i,(a,b) in enumerate(rows):
  y=27+i*39;s+=text(331,y,a,13,'#DF9FA4' if i>=10 else TXT)+text(578,y,b,11,MUTED)
 return s

def zen():
 s=screen();s+=rect(77,0,1023,35,PANEL)+text(474,23,'localhost / dev / editor',11,MUTED)+rect(0,676,1100,24,BG)
 return s

def recovery():
 s=screen().replace('localhost','production').replace('Connected · tmux','Disconnected · Read-only')
 s+=rect(0,36,1100,62,'#392F25')+text(19,58,'Connection lost · production / dev',13,'#E5BC83',weight=600)+text(19,80,'Last received output. Input is paused; your tmux session may still be running.',12,'#C8B69F')+button(929,51,153,'Reattach session')
 return s

def close():
 s=screen()+popup(312,217,476,244)+text(337,255,'Close Terminal 1?',21,TXT,weight=600)+text(337,288,'localhost · Original shell + tmux session dev',12,ACC)+text(337,322,'The original shell will close; its commands may stop.',12,TXT)+text(337,345,'tmux will detach. Its remote tasks keep running.',12,TXT)+button(520,409,104,'Cancel')+button(636,409,126,'Close tab')
 return s

def empty():
 s=plain()+rect(77,0,1023,35,PANEL)+text(501,23,'Tether',12,MUTED)+rect(0,36,1100,640,BG)+text(422,285,'No open terminals',24,TXT,weight=600)+text(326,324,'Choose File → New terminal or tmux → Attach session.',15,MUTED)+text(355,356,'Ctrl⇧P opens all commands. ⌘N opens a terminal.',13,MUTED)
 return s

def manage():
 s=plain()+popup(254,112,592,487)+text(280,151,'Manage hosts',22,TXT,weight=600)+text(280,180,'Saved in ~/.ssh/config',12,MUTED)
 for i,(a,b) in enumerate([('localhost','Local machine · cannot be removed'),('production','deploy@prod.example.com'),('staging','deploy@stage.example.com'),('lab','roy@lab.example.com')]):
  y=222+i*66;s+=text(282,y,a,14,TXT)+text(282,y+22,b,11,MUTED)+line(278,y+38,821,y+38)
  if i>0:s+=text(711,y+10,'Edit…',12,ACC)+text(770,y+10,'Delete',12,MUTED)
 s+=button(280,545,120,'Add host…')+button(722,545,98,'Done')
 return s

def settings():
 s=plain()+popup(258,122,584,462)+text(284,160,'Settings',22,TXT,weight=600)+text(285,207,'Appearance',13,TXT)+text(604,207,'System  ▾',13,ACC)+line(282,229,818,229)+text(285,265,'Terminal font size',13,TXT)+text(604,265,'13 pt  −  +',13,ACC)+text(285,313,'Open localhost at launch',13,TXT)+text(688,313,'On',13,ACC)+line(282,339,818,339)+text(285,376,'Extensions',13,TXT,weight=600)+text(300,415,'tmux',13,TXT)+text(688,415,'Enabled',13,ACC)+text(300,451,'Nerve',13,TXT)+text(688,451,'Enabled',13,ACC)+text(286,541,'⌘, opens Settings',12,MUTED)
 return s

def inspector():
 s=screen()+rect(0,36,820,640,BG)+term(20,70,'editor')+line(420,36,420,676)+term(437,70,'logs')+line(420,350,820,350)+term(437,380,'git')+rect(820,36,280,640,PANEL)+line(820,36,820,676)+text(840,77,'Inspector',18,TXT,weight=600)
 for i,(a,b) in enumerate([('Host','localhost'),('Session','dev'),('Window','editor'),('Active pane','1 · vim'),('Size','80 × 30'),('Connection','Connected')]):
  y=117+i*61;s+=text(840,y,a,11,MUTED)+text(840,y+24,b,13,TXT)
 return s
states=[
 ('01-shell','Ordinary terminal','One top tab strip. Menus own actions; the host selector stays at the bottom left.',plain()),
 ('02-tmux','tmux workspace','The same terminal tab shows a tmux session/window. Panes remain spatial content.',screen()),
 ('03-session-tree','Tab session tree','Click the active tab again or its chevron. Sessions → windows; no extra top tabs.',screen(True)),
 ('04-host','Host switcher','Switch host and restore its last workspace. Search, Add and Manage remain discoverable.',host()),
 ('05-quick-switch','Quick switch · ⌘P','Jump to host/session/window directly. Highlight does not connect or switch.',command(True)),
 ('06-command','Command menu · Ctrl⇧P','Same commands and enabled states as macOS menus. ⌘⇧P is also supported.',command()),
 ('07-native-menu','macOS menu bar','Mouse operations live in the native menu bar. This bar is outside the app window.',menus()),
 ('08-zen','Zen Mode · ⌘⇧Z','Hide tabs/status; retain panes. Exit through View menu or command menu.',zen()),
 ('09-recovery','Disconnected / recovery','Keep last output read-only. Reattach the same session; never replay buffered input.',recovery()),
 ('10-close','Close workspace confirmation','Close original shell and detach owned sessions. Ending remote work is a separate action.',close()),
 ('11-empty','No open terminals','Stay on the same host. Direct users to native menus and commands; no action toolbar.',empty()),
 ('12-hosts','Manage hosts','A separate sheet opened from the host selector. Preserve existing SSH config semantics.',manage()),
 ('13-connect','Connect / authenticate','Cancel leaves the current workspace intact. Host-key trust remains a separate explicit step.',sheet('Connect to production','deploy@prod.example.com · SSH', [('Authentication','Password'),('Password','••••••••••'),('Remember password','Off')],'Connect')),
 ('14-new-session','Create tmux session','Explicit creation on the selected host. A failed or missing session never creates one silently.',sheet('Create tmux session','localhost · Default tmux socket',[('Session name','dev'),('After creation','Open in Terminal 1')],'Create')),
 ('15-settings','Settings · ⌘,','Separate settings window; native appearance and terminal preferences remain available.',settings()),
 ('16-inspector','Inspector · View menu','Optional metadata panel, hidden by default and in Zen. No persistent inspector button.',inspector())]
manifest=[]
for i,(key,title,desc,content) in enumerate(states):
 board=rect(0,0,1160,826,'#101318')+text(30,35,f'{i+1:02}  {title}',21,TXT,weight=600)+text(30,62,desc,12,MUTED)
 if key=='07-native-menu':
  board+=rect(30,77,1100,24,'#292D34')
  for x,label in [(15,'●'),(47,'Tether'),(116,'File'),(160,'Edit'),(207,'View'),(258,'Terminal'),(334,'tmux'),(392,'Window'),(474,'Help')]:board+=text(30+x,94,label,11,TXT)
 board+=f'<g transform="translate(30,101)">{content}</g>'
 (p/f'{key}.svg').write_text(svg(board,1160,826));manifest.append({'key':key,'name':f'{i+1:02} · {title}','file':f'{key}.svg','x':(i%4)*1240,'y':(i//4)*920})
previous = json.loads((p/'manifest.json').read_text()) if (p/'manifest.json').exists() else []
ids = {m['key']:m.get('figmaNodeId') for m in previous}
for item in manifest:
 if ids.get(item['key']): item['figmaNodeId']=ids[item['key']]
(p/'manifest.json').write_text(json.dumps(manifest,indent=2))
(p/'index.html').write_text('<!doctype html><meta charset="utf-8"><title>Tether · Page 6 final</title><style>body{background:#101318;color:#d9dfe8;font:16px system-ui;margin:32px}main{display:grid;grid-template-columns:repeat(2,minmax(0,1fr));gap:24px}img{width:100%}a{color:#8faef0}</style><h1>Tether · Page 6 final</h1><p>One top tab strip · tmux session tree · native macOS menus</p><main>'+''.join(f'<a href="{m["file"]}"><img src="{m["file"]}" alt="{m["name"]}"></a>' for m in manifest)+'</main>')
print('Generated',len(manifest),'final screens')
