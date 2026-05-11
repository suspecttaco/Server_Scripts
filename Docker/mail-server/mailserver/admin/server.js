const http = require('http');
const fs = require('fs');
const path = require('path');
const { execSync } = require('child_process');
const crypto = require('crypto');

const PORT = 8080;
const DOMAIN = process.env.MAIL_DOMAIN || 'mail.local';
const ADMIN_USER = process.env.ADMIN_USER || 'admin';
const ADMIN_PASS = process.env.ADMIN_PASS || 'Admin2024!';
const USERS_FILE = '/etc/dovecot/users';

const sessions = new Set();

function genToken() {
  return crypto.randomBytes(32).toString('hex');
}

function validSession(req) {
  const cookie = (req.headers.cookie || '').split(';').find(c => c.trim().startsWith('session='));
  if (!cookie) return false;
  return sessions.has(cookie.split('=')[1]);
}

function exec(cmd) {
  try { return { ok: true, out: execSync(cmd, { encoding: 'utf8', shell: '/bin/bash' }) }; }
  catch (e) { return { ok: false, out: e.stderr || e.message }; }
}

function json(res, data, code = 200, setCookie = null) {
  const headers = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*' };
  if (setCookie) headers['Set-Cookie'] = setCookie;
  res.writeHead(code, headers);
  res.end(JSON.stringify(data));
}

function readUsers() {
  if (!fs.existsSync(USERS_FILE)) return [];
  return fs.readFileSync(USERS_FILE, 'utf8').trim().split('\n')
    .filter(l => l.trim())
    .map(l => {
      const parts = l.split(':');
      return { email: parts[0], home: parts[5] || '' };
    });
}

const routes = {
  'POST /api/login': (req, res, body) => {
    if (body.user === ADMIN_USER && body.pass === ADMIN_PASS) {
      const token = genToken();
      sessions.add(token);
      return json(res, { ok: true }, 200, `session=${token}; HttpOnly; Path=/`);
    }
    json(res, { ok: false, message: 'Credenciales incorrectas' }, 401);
  },

  'POST /api/logout': (req, res) => {
    const cookie = (req.headers.cookie || '').split(';').find(c => c.trim().startsWith('session='));
    if (cookie) sessions.delete(cookie.split('=')[1]);
    json(res, { ok: true }, 200, 'session=; Max-Age=0; Path=/');
  },

  'GET /api/accounts': (req, res) => {
    json(res, { ok: true, accounts: readUsers() });
  },

  'POST /api/accounts': (req, res, body) => {
    const { user, pass } = body;
    if (!user || !pass) return json(res, { ok: false, message: 'Usuario y contrasena requeridos' });
    const email = `${user}@${DOMAIN}`;
    if (readUsers().find(u => u.email === email)) return json(res, { ok: false, message: 'La cuenta ya existe' });
    const r = exec(`doveadm pw -s SHA512-CRYPT -p '${pass}'`);
    if (!r.ok) return json(res, { ok: false, message: 'Error generando hash' });
    const hash = r.out.trim();
    const home = `/var/mail/${user}`;
    const maildir = `${home}/Maildir`;
    exec(`mkdir -p ${maildir}/{cur,new,tmp}`);
    ['Drafts','Sent','Junk','Trash'].forEach(f => exec(`mkdir -p ${maildir}/.${f}/{cur,new,tmp}`));
    exec(`chown -R vmail:vmail ${home} && chmod -R 700 ${home}`);
    fs.appendFileSync(USERS_FILE, `${email}:${hash}:1000:1000::${home}:\n`);
    const vmailbox = '/etc/postfix/vmailbox';
    fs.appendFileSync(vmailbox, `${email}   ${user}/Maildir/\n`);
    exec(`postmap ${vmailbox}`);
    json(res, { ok: true, message: `Cuenta ${email} creada` });
  },

  'PUT /api/accounts/:user/password': (req, res, body, params) => {
    const { pass } = body;
    if (!pass) return json(res, { ok: false, message: 'Contrasena requerida' });
    const email = `${params.user}@${DOMAIN}`;
    if (!readUsers().find(u => u.email === email)) return json(res, { ok: false, message: 'Cuenta no encontrada' });
    const r = exec(`doveadm pw -s SHA512-CRYPT -p '${pass}'`);
    if (!r.ok) return json(res, { ok: false, message: 'Error generando hash' });
    const hash = r.out.trim();
    const content = fs.readFileSync(USERS_FILE, 'utf8');
    const updated = content.split('\n').map(l => {
      if (l.startsWith(email + ':')) { const p = l.split(':'); p[1] = hash; return p.join(':'); }
      return l;
    }).join('\n');
    fs.writeFileSync(USERS_FILE, updated);
    json(res, { ok: true, message: `Contrasena de ${email} actualizada` });
  },

  'DELETE /api/accounts/:user': (req, res, body, params) => {
    const email = `${params.user}@${DOMAIN}`;
    const content = fs.readFileSync(USERS_FILE, 'utf8');
    const updated = content.split('\n').filter(l => !l.startsWith(email + ':')).join('\n');
    fs.writeFileSync(USERS_FILE, updated);
    json(res, { ok: true, message: `Cuenta ${email} eliminada` });
  },

  'GET /api/ips': (req, res) => {
    const r = exec("fail2ban-client status dovecot 2>/dev/null | grep 'Banned IP' | sed 's/.*Banned IP list://'");
    const ips = r.ok ? r.out.trim().split(/\s+/).filter(Boolean).map(ip => ({ ip, jail: 'dovecot' })) : [];
    json(res, { ok: true, banned: ips });
  },

  'POST /api/ips/ban': (req, res, body) => {
    const { ip, jail } = body;
    if (!ip) return json(res, { ok: false, message: 'IP requerida' });
    const r = exec(`fail2ban-client set ${jail} banip ${ip}`);
    json(res, { ok: r.ok, message: r.ok ? `${ip} baneada` : r.out });
  },

  'POST /api/ips/unban': (req, res, body) => {
    const { ip, jail } = body;
    const r = exec(`fail2ban-client set ${jail} unbanip ${ip}`);
    json(res, { ok: r.ok, message: r.ok ? `${ip} desbaneada` : r.out });
  },

  'GET /api/config': (req, res) => {
    json(res, { ok: true, domain: DOMAIN, hostname: process.env.MAIL_HOSTNAME || `mail.${DOMAIN}` });
  },

  'GET /api/status': (req, res) => {
    const r = exec('supervisorctl status 2>/dev/null');
    const services = r.out.trim().split('\n')
      .filter(l => l.trim() && !l.includes('UserWarning') && !l.includes('import'))
      .map(l => { const p = l.trim().split(/\s+/); return { name: p[0], running: p[1] === 'RUNNING' }; });
    json(res, { ok: true, services });
  },

  'POST /api/backup': (req, res) => {
    const r = exec('/usr/local/bin/mail_backup.sh');
    json(res, { ok: r.ok, message: r.ok ? 'Backup completado' : r.out });
  },

  'GET /api/logs/maillog': (req, res) => {
    const r = exec('tail -100 /var/log/maillog 2>/dev/null');
    json(res, { ok: true, content: r.out || 'Sin entradas' });
  },

  'GET /api/logs/dovecot': (req, res) => {
    const r = exec('tail -100 /var/log/dovecot-info.log 2>/dev/null');
    json(res, { ok: true, content: r.out || 'Sin entradas' });
  },

  'GET /api/logs/fail2ban': (req, res) => {
    const r = exec('tail -100 /var/log/fail2ban.log 2>/dev/null');
    json(res, { ok: true, content: r.out || 'Sin entradas' });
  },
};

const PUBLIC = ['/api/login'];

http.createServer((req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'GET,POST,PUT,DELETE', 'Access-Control-Allow-Headers': 'Content-Type,Cookie' });
    return res.end();
  }

  if (req.method === 'GET' && (req.url === '/' || req.url === '/index.html')) {
    res.writeHead(200, { 'Content-Type': 'text/html' });
    return res.end(fs.readFileSync(path.join(__dirname, 'index.html')));
  }

  const urlPath = req.url.split('?')[0];
  const isPublic = PUBLIC.includes(urlPath);

  if (!isPublic && !validSession(req)) {
    return json(res, { ok: false, message: 'No autorizado' }, 401);
  }

  let handler = null;
  let params = {};
  const key = `${req.method} ${urlPath}`;

  if (routes[key]) {
    handler = routes[key];
  } else {
    for (const route of Object.keys(routes)) {
      const [method, pattern] = route.split(' ');
      if (method !== req.method) continue;
      const regex = new RegExp('^' + pattern.replace(/:(\w+)/g, '(?<$1>[^/]+)') + '$');
      const match = urlPath.match(regex);
      if (match) { handler = routes[route]; params = match.groups || {}; break; }
    }
  }

  if (!handler) { res.writeHead(404); return res.end('Not found'); }

  let body = '';
  req.on('data', d => body += d);
  req.on('end', () => {
    try { handler(req, res, body ? JSON.parse(body) : {}, params); }
    catch (e) { json(res, { ok: false, message: e.message }, 500); }
  });
}).listen(PORT, () => console.log(`admin: escuchando en puerto ${PORT}`));