import fs from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import webpack from 'webpack';
import getPublicLibConfig from '../webpack.config.js';

const outputDirectory = process.argv[2];
if (!outputDirectory) {
    throw new Error('Usage: node ios/build-frontend.mjs <output-directory>');
}

fs.mkdirSync(outputDirectory, { recursive: true });
const config = getPublicLibConfig({ forceDist: true });
config.output = {
    ...config.output,
    path: path.resolve(outputDirectory),
    filename: 'lib.ios.js',
};
config.cache = false;

const compiler = webpack(config);
await new Promise((resolve, reject) => {
    compiler.run((error, stats) => {
        compiler.close((closeError) => {
            if (error || closeError || stats?.hasErrors()) {
                reject(error ?? closeError ?? new Error(stats?.toString({ all: false, errors: true })));
            } else {
                resolve();
            }
        });
    });
});
