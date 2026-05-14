import { render } from 'preact';
import './styles.css';
import { App } from './app';

const root = document.getElementById('app');
if (!root) throw new Error('#app missing in index.html');
render(<App />, root);
