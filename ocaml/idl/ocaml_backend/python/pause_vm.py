#!/usr/bin/python

import xmlrpclib
server = xmlrpclib.Server("http://localhost:8086");
session = server.Session.do_login_with_password("user", "passwd")['Value']
server.VM.do_pause(session, '7366a41a-e50e-b891-fa0c-ca5b4d2e3f1c')
