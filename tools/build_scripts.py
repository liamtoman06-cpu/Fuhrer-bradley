"""Packs src/*.lua into KingBradleyScripts.rbxmx: a Folder with the 6 scripts to drop into the
imported KingBradley model.   python3 tools/build_scripts.py"""
import os
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
items = [("ModuleScript", "Config", "Config.lua", None), ("ModuleScript", "Motion", "Motion.lua", None),
         ("ModuleScript", "Poses", "Poses.lua", None), ("ModuleScript", "Animator", "Animator.lua", None),
         ("Script", "BossServer", "BossServer.server.lua", 1), ("Script", "BossClient", "BossClient.client.lua", 2)]
out = ['<roblox xmlns:xmime="http://www.w3.org/2005/05/xmlmime" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" xsi:noNamespaceSchemaLocation="http://www.roblox.com/roblox.xsd" version="4">',
       '<External>null</External><External>nil</External>',
       '<Item class="Folder" referent="RBX000001"><Properties><string name="Name">KingBradleyScripts</string></Properties>']
for i, (cls, name, fname, ctx) in enumerate(items):
    src = open(os.path.join(ROOT, "src", fname), encoding="utf-8").read()
    assert "]]>" not in src
    props = [f'<string name="Name">{name}</string>']
    if ctx:
        props += [f'<token name="RunContext">{ctx}</token>', '<bool name="Disabled">false</bool>']
    props.append(f'<ProtectedString name="Source"><![CDATA[{src}]]></ProtectedString>')
    out.append(f'<Item class="{cls}" referent="RBX{i + 2:06d}"><Properties>' + "".join(props) + "</Properties></Item>")
out.append("</Item></roblox>")
open(os.path.join(ROOT, "KingBradleyScripts.rbxmx"), "w", encoding="utf-8").write("\n".join(out))
print("KingBradleyScripts.rbxmx written")
